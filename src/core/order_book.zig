//! Single-symbol order book with price-time priority matching.
//!
//! Design principles:
//! - Price-time priority: best price first, then FIFO at each level
//! - O(1) order lookup via hash map
//! - O(n) price level operations (acceptable for typical 10-100 levels)
//! - Zero allocation in hot path (uses pre-allocated pools)
//! - Bounded iterations prevent runaway matching
//!
//! Memory footprint:
//! - Price levels: 2 × MAX_PRICE_LEVELS × 64 bytes = 1.25 MB
//! - Order map: ORDER_MAP_SIZE × 24 bytes ≈ 6 MB
//! - Total: ~7.5 MB per order book
//!
//! Thread Safety:
//! - NOT thread-safe. Single-threaded access only.
//! - For multi-symbol engines, each book should be owned by one thread.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const Order = @import("order.zig").Order;
const getCurrentTimestamp = @import("order.zig").getCurrentTimestamp;
const MemoryPools = @import("memory_pool.zig").MemoryPools;

// ============================================================================
// Configuration
// ============================================================================

/// Maximum price levels per side.
/// Typical liquid markets have 10-50 levels; 10K provides headroom.
pub const MAX_PRICE_LEVELS: u32 = 10_000;

/// Maximum output messages per processing cycle.
/// Sized for worst case: large order sweeping entire book.
pub const MAX_OUTPUT_MESSAGES: u32 = 8_192;

/// Order map capacity. Must be power of 2.
/// 256K slots at ~75% load = ~192K orders per book.
pub const ORDER_MAP_SIZE: u32 = 262_144;
pub const ORDER_MAP_MASK: u32 = ORDER_MAP_SIZE - 1;

/// Maximum probe length for order map.
pub const MAX_PROBE_LENGTH: u32 = 128;

/// Maximum iterations in matching loop.
/// Prevents runaway matching on pathological order flow.
pub const MAX_MATCH_ITERATIONS: u32 = 200_000;

/// Tombstone compaction threshold (percentage of capacity).
/// When tombstone_count exceeds this, compact on next insert.
const TOMBSTONE_COMPACT_THRESHOLD: u32 = 25;

/// Load factor warning threshold (percentage).
const LOAD_FACTOR_WARNING: u32 = 75;

// Compile-time verification
comptime {
    std.debug.assert(ORDER_MAP_SIZE & (ORDER_MAP_SIZE - 1) == 0);
    std.debug.assert(MAX_PROBE_LENGTH > 0);
    std.debug.assert(MAX_PROBE_LENGTH <= ORDER_MAP_SIZE);
    std.debug.assert(MAX_PRICE_LEVELS > 0);
    std.debug.assert(MAX_OUTPUT_MESSAGES > 0);
}

// ============================================================================
// Hash Map Sentinels
// ============================================================================

/// Empty slot marker (key that will never be used).
const HASH_SLOT_EMPTY: u64 = 0;

/// Tombstone marker for deleted slots.
const HASH_SLOT_TOMBSTONE: u64 = std.math.maxInt(u64);

// ============================================================================
// Order Location
// ============================================================================

/// Location of an order in the book (for O(1) cancel).
pub const OrderLocation = struct {
    side: msg.Side,
    price: u32,
    order_ptr: *Order,

    /// Validate location is consistent.
    pub fn isValid(self: *const OrderLocation) bool {
        if (self.order_ptr.price != self.price) return false;
        if (self.order_ptr.side != self.side) return false;
        return true;
    }
};

// ============================================================================
// Order Hash Map
// ============================================================================

const OrderMapSlot = struct {
    key: u64,
    location: OrderLocation,
};

/// Hash map for O(1) order lookup by (user_id, order_id).
///
/// Uses open addressing with linear probing and tombstones.
/// Supports automatic compaction when tombstone ratio is high.
pub const OrderMap = struct {
    slots: [ORDER_MAP_SIZE]OrderMapSlot = undefined,

    /// Number of active entries.
    count: u32 = 0,

    /// Number of tombstone slots.
    tombstone_count: u32 = 0,

    /// Statistics
    total_inserts: u64 = 0,
    total_removes: u64 = 0,
    total_lookups: u64 = 0,
    probe_total: u64 = 0,
    max_probe: u32 = 0,
    compactions: u32 = 0,

    const Self = @This();

    /// Initialize empty map.
    pub fn init() Self {
        var self = Self{};
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }
        return self;
    }

    /// Create composite key from user_id and order_id.
    pub inline fn makeKey(user_id: u32, user_order_id: u32) u64 {
        // Ensure key is never 0 or maxInt (our sentinels)
        const raw = (@as(u64, user_id) << 32) | user_order_id;
        std.debug.assert(raw != HASH_SLOT_EMPTY);
        std.debug.assert(raw != HASH_SLOT_TOMBSTONE);
        return raw;
    }

    /// Multiplicative hash using golden ratio.
    inline fn hash(key: u64) u32 {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);

        const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;
        var k = key;
        k ^= k >> 33;
        k *%= GOLDEN_RATIO;
        k ^= k >> 29;
        return @intCast(k & ORDER_MAP_MASK);
    }

    /// Insert order location into map.
    /// Returns true on success, false if map is full.
    pub fn insert(self: *Self, key: u64, location: OrderLocation) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);
        std.debug.assert(location.order_ptr.remaining_qty > 0);

        // Check if compaction needed
        if (self.shouldCompact()) {
            self.compact();
        }

        var idx = hash(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_key = self.slots[idx].key;

            if (slot_key == HASH_SLOT_EMPTY or slot_key == HASH_SLOT_TOMBSTONE) {
                const was_tombstone = (slot_key == HASH_SLOT_TOMBSTONE);

                self.slots[idx] = .{ .key = key, .location = location };
                self.count += 1;

                if (was_tombstone) {
                    std.debug.assert(self.tombstone_count > 0);
                    self.tombstone_count -= 1;
                }

                self.recordProbe(probe);
                self.total_inserts += 1;

                // Post-condition
                std.debug.assert(self.count <= ORDER_MAP_SIZE);
                return true;
            }

            // Check for duplicate key (shouldn't happen with valid usage)
            if (slot_key == key) {
                std.debug.panic("OrderMap.insert: duplicate key {}", .{key});
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        // Probe limit exceeded
        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    /// Find order location by key.
    /// Returns null if not found.
    pub fn find(self: *Self, key: u64) ?*const OrderLocation {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);

        var idx = hash(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot = &self.slots[idx];

            if (slot.key == HASH_SLOT_EMPTY) {
                self.recordProbe(probe);
                self.total_lookups += 1;
                return null;
            }

            if (slot.key == key) {
                self.recordProbe(probe);
                self.total_lookups += 1;
                return &slot.location;
            }

            // Skip tombstones during search
            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        self.total_lookups += 1;
        return null;
    }

    /// Remove order from map.
    /// Returns true if found and removed, false if not found.
    pub fn remove(self: *Self, key: u64) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);

        var idx = hash(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot = &self.slots[idx];

            if (slot.key == HASH_SLOT_EMPTY) {
                self.recordProbe(probe);
                return false;
            }

            if (slot.key == key) {
                slot.key = HASH_SLOT_TOMBSTONE;

                std.debug.assert(self.count > 0);
                self.count -= 1;
                self.tombstone_count += 1;

                self.recordProbe(probe);
                self.total_removes += 1;
                return true;
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    /// Check if compaction is needed.
    fn shouldCompact(self: *const Self) bool {
        const threshold = ORDER_MAP_SIZE * TOMBSTONE_COMPACT_THRESHOLD / 100;
        return self.tombstone_count > threshold;
    }

    /// Compact map by rehashing all entries.
    /// Removes tombstones and improves probe lengths.
    fn compact(self: *Self) void {
        // Collect all active entries
        var entries: [ORDER_MAP_SIZE]OrderMapSlot = undefined;
        var entry_count: u32 = 0;

        for (&self.slots) |*slot| {
            if (slot.key != HASH_SLOT_EMPTY and slot.key != HASH_SLOT_TOMBSTONE) {
                entries[entry_count] = slot.*;
                entry_count += 1;
            }
        }

        std.debug.assert(entry_count == self.count);

        // Clear all slots
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }

        // Reinsert all entries
        const old_count = self.count;
        self.count = 0;
        self.tombstone_count = 0;

        for (entries[0..entry_count]) |entry| {
            const success = self.insertInternal(entry.key, entry.location);
            std.debug.assert(success);
        }

        std.debug.assert(self.count == old_count);
        self.compactions += 1;
    }

    /// Internal insert without compaction check (used during compaction).
    fn insertInternal(self: *Self, key: u64, location: OrderLocation) bool {
        var idx = hash(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            if (self.slots[idx].key == HASH_SLOT_EMPTY) {
                self.slots[idx] = .{ .key = key, .location = location };
                self.count += 1;
                return true;
            }
            idx = (idx + 1) & ORDER_MAP_MASK;
        }
        return false;
    }

    fn recordProbe(self: *Self, probe_length: u32) void {
        self.probe_total += probe_length;
        self.max_probe = @max(self.max_probe, probe_length);
    }

    /// Get current load factor (0-100).
    pub fn getLoadFactor(self: *const Self) u32 {
        return (self.count * 100) / ORDER_MAP_SIZE;
    }

    /// Check map invariants.
    pub fn isValid(self: *const Self) bool {
        if (self.count > ORDER_MAP_SIZE) return false;
        if (self.tombstone_count > ORDER_MAP_SIZE) return false;
        if (self.count + self.tombstone_count > ORDER_MAP_SIZE) return false;
        return true;
    }
};

// ============================================================================
// Price Level
// ============================================================================

/// A single price level containing orders at the same price.
///
/// Orders are maintained in FIFO order via doubly-linked list.
/// Exactly 64 bytes (one cache line) for optimal memory access.
pub const PriceLevel = extern struct {
    /// Price in ticks.
    price: u32,

    /// Sum of remaining_qty for all orders at this level.
    total_quantity: u32,

    /// Head of order list (oldest order, highest time priority).
    orders_head: ?*Order,

    /// Tail of order list (newest order).
    orders_tail: ?*Order,

    /// Number of orders at this level.
    order_count: u32,

    /// Whether this level has any orders.
    active: bool,

    /// Padding to fill cache line.
    _padding: [35]u8 = undefined,

    // Compile-time size verification
    comptime {
        std.debug.assert(@sizeOf(@This()) == 64);
    }

    const Self = @This();

    /// Initialize empty price level.
    pub fn init(price: u32) Self {
        return .{
            .price = price,
            .total_quantity = 0,
            .orders_head = null,
            .orders_tail = null,
            .order_count = 0,
            .active = false,
        };
    }

    /// Check level invariants.
    pub fn isValid(self: *const Self) bool {
        // Both head and tail must be null or both non-null
        const head_null = (self.orders_head == null);
        const tail_null = (self.orders_tail == null);
        if (head_null != tail_null) return false;

        // Active must match whether we have orders
        if (self.active != !head_null) return false;

        // If no orders, count and quantity must be zero
        if (head_null) {
            if (self.order_count != 0) return false;
            if (self.total_quantity != 0) return false;
        } else {
            if (self.order_count == 0) return false;
        }

        return true;
    }

    /// Add order to tail of list (FIFO).
    pub fn addOrder(self: *Self, order: *Order) void {
        // Pre-conditions
        std.debug.assert(order.price == self.price);
        std.debug.assert(order.remaining_qty > 0);
        std.debug.assert(order.next == null);
        std.debug.assert(order.prev == null);

        // Link to tail
        order.prev = self.orders_tail;

        if (self.orders_tail) |tail| {
            std.debug.assert(tail.next == null);
            tail.next = order;
        } else {
            // First order at this level
            std.debug.assert(self.orders_head == null);
            self.orders_head = order;
        }

        self.orders_tail = order;
        self.total_quantity += order.remaining_qty;
        self.order_count += 1;
        self.active = true;

        // Post-condition
        std.debug.assert(self.isValid());
    }

    /// Remove order from list.
    pub fn removeOrder(self: *Self, order: *Order) void {
        // Pre-conditions
        std.debug.assert(self.active);
        std.debug.assert(self.order_count > 0);
        std.debug.assert(order.price == self.price);

        // Verify quantity won't underflow
        std.debug.assert(self.total_quantity >= order.remaining_qty);

        // Update quantity (use checked subtraction, not saturating)
        self.total_quantity -= order.remaining_qty;

        // Unlink from list
        if (order.prev) |prev| {
            prev.next = order.next;
        } else {
            // Was head
            std.debug.assert(self.orders_head == order);
            self.orders_head = order.next;
        }

        if (order.next) |next| {
            next.prev = order.prev;
        } else {
            // Was tail
            std.debug.assert(self.orders_tail == order);
            self.orders_tail = order.prev;
        }

        // Clear order's links
        order.next = null;
        order.prev = null;

        // Update count
        self.order_count -= 1;

        // Update active status
        if (self.orders_head == null) {
            self.active = false;
            std.debug.assert(self.order_count == 0);
            std.debug.assert(self.total_quantity == 0);
        }

        // Post-condition
        std.debug.assert(self.isValid());
    }

    /// Update total quantity after partial fill.
    /// Use this instead of direct modification for invariant checking.
    pub fn reduceQuantity(self: *Self, amount: u32) void {
        std.debug.assert(self.total_quantity >= amount);
        self.total_quantity -= amount;
    }
};

// ============================================================================
// Output Buffer
// ============================================================================

/// Buffer for output messages generated during order processing.
///
/// Messages are accumulated during processing and sent in batch.
/// Tracks overflow for diagnostics.
pub const OutputBuffer = struct {
    messages: [MAX_OUTPUT_MESSAGES]msg.OutputMsg = undefined,
    count: u32 = 0,

    /// Number of messages dropped due to overflow.
    overflow_count: u64 = 0,

    /// High water mark.
    peak_count: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    /// Check if buffer has space for N messages.
    pub fn hasSpace(self: *const Self, needed: u32) bool {
        return (self.count + needed) <= MAX_OUTPUT_MESSAGES;
    }

    /// Add message to buffer.
    /// Returns true if added, false if buffer is full.
    pub fn add(self: *Self, message: msg.OutputMsg) bool {
        if (self.count >= MAX_OUTPUT_MESSAGES) {
            self.overflow_count += 1;
            return false;
        }

        self.messages[self.count] = message;
        self.count += 1;
        self.peak_count = @max(self.peak_count, self.count);

        return true;
    }

    /// Add message, asserting that buffer has space.
    /// Use when overflow would indicate a logic error.
    pub fn addChecked(self: *Self, message: msg.OutputMsg) void {
        const success = self.add(message);
        std.debug.assert(success);
    }

    /// Clear buffer for reuse.
    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    /// Get slice of buffered messages.
    pub fn slice(self: *const Self) []const msg.OutputMsg {
        return self.messages[0..self.count];
    }

    /// Check if buffer has overflowed.
    pub fn hasOverflowed(self: *const Self) bool {
        return self.overflow_count > 0;
    }
};

// ============================================================================
// Order Book Statistics
// ============================================================================

/// Statistics for order book operations.
pub const OrderBookStats = struct {
    total_orders: u64,
    total_cancels: u64,
    total_trades: u64,
    total_rejects: u64,
    total_fills: u64,
    volume_traded: u64,
    current_bid_levels: u32,
    current_ask_levels: u32,
    current_orders: u32,
    order_map_load_factor: u32,
};

// ============================================================================
// Order Book
// ============================================================================

/// Single-symbol order book with price-time priority matching.
///
/// The book maintains two sorted arrays of price levels (bids descending,
/// asks ascending) and a hash map for O(1) order lookup.
pub const OrderBook = struct {
    // === Symbol ===
    symbol: msg.Symbol,

    // === Price Levels ===
    /// Bid levels sorted by price descending (best bid first).
    bids: [MAX_PRICE_LEVELS]PriceLevel = undefined,

    /// Ask levels sorted by price ascending (best ask first).
    asks: [MAX_PRICE_LEVELS]PriceLevel = undefined,

    /// Number of active bid levels.
    num_bid_levels: u32 = 0,

    /// Number of active ask levels.
    num_ask_levels: u32 = 0,

    // === Order Lookup ===
    order_map: OrderMap,

    // === Top of Book Cache ===
    prev_best_bid_price: u32 = 0,
    prev_best_bid_qty: u32 = 0,
    prev_best_ask_price: u32 = 0,
    prev_best_ask_qty: u32 = 0,

    // === Memory Pool ===
    pools: *MemoryPools,

    // === Statistics ===
    total_orders: u64 = 0,
    total_cancels: u64 = 0,
    total_trades: u64 = 0,
    total_rejects: u64 = 0,
    total_fills: u64 = 0,
    volume_traded: u64 = 0,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize order book for symbol.
    pub fn init(symbol: msg.Symbol, pools: *MemoryPools) Self {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));
        std.debug.assert(pools.order_pool.capacity > 0);

        var book = Self{
            .symbol = symbol,
            .order_map = OrderMap.init(),
            .pools = pools,
        };

        // Initialize all price levels
        for (&book.bids) |*level| {
            level.* = PriceLevel.init(0);
        }
        for (&book.asks) |*level| {
            level.* = PriceLevel.init(0);
        }

        std.debug.assert(book.isValid());
        return book;
    }

    /// Reset book for reuse with new symbol.
    /// Releases all orders back to pool.
    pub fn reset(self: *Self, symbol: msg.Symbol) void {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        // Release all orders back to pool
        self.releaseAllOrders();

        // Reset state
        self.symbol = symbol;
        self.num_bid_levels = 0;
        self.num_ask_levels = 0;
        self.order_map = OrderMap.init();
        self.prev_best_bid_price = 0;
        self.prev_best_bid_qty = 0;
        self.prev_best_ask_price = 0;
        self.prev_best_ask_qty = 0;

        std.debug.assert(self.isValid());
    }

    /// Check book invariants.
    fn isValid(self: *const Self) bool {
        if (self.num_bid_levels > MAX_PRICE_LEVELS) return false;
        if (self.num_ask_levels > MAX_PRICE_LEVELS) return false;
        if (!self.order_map.isValid()) return false;
        return true;
    }

    // ========================================================================
    // Order Entry
    // ========================================================================

    /// Add new order to book.
    pub fn addOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());

        self.total_orders += 1;

        // Validate quantity
        if (order_msg.quantity == 0) {
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                order_msg.user_id,
                order_msg.user_order_id,
                .invalid_quantity,
                self.symbol,
                client_id,
            ));
            return;
        }

        // Acquire order from pool
        const order = self.pools.order_pool.acquire() orelse {
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                order_msg.user_id,
                order_msg.user_order_id,
                .pool_exhausted,
                self.symbol,
                client_id,
            ));
            return;
        };

        // Initialize order
        const timestamp = getCurrentTimestamp();
        order.* = Order.init(order_msg, client_id, timestamp);

        std.debug.assert(order.isValid());

        // Send acknowledgment
        _ = output.add(msg.OutputMsg.makeAck(
            order.user_id,
            order.user_order_id,
            self.symbol,
            client_id,
        ));

        // Attempt to match
        self.matchOrder(order, client_id, output);

        // If not fully filled, add to book
        if (!order.isFilled()) {
            const inserted = self.insertOrder(order);
            if (!inserted) {
                // Book is full - shouldn't happen with proper sizing
                std.log.err("Order book full, rejecting order", .{});
                self.total_rejects += 1;
                _ = output.add(msg.OutputMsg.makeReject(
                    order.user_id,
                    order.user_order_id,
                    .book_full,
                    self.symbol,
                    client_id,
                ));
                self.pools.order_pool.release(order);
                return;
            }
            self.checkTopOfBookChange(output);
        } else {
            // Fully filled, return to pool
            self.pools.order_pool.release(order);
        }

        std.debug.assert(self.isValid());
    }

    // ========================================================================
    // Order Cancellation
    // ========================================================================

    /// Cancel order by user_id and order_id.
    pub fn cancelOrder(
        self: *Self,
        user_id: u32,
        user_order_id: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());

        self.total_cancels += 1;

        const key = OrderMap.makeKey(user_id, user_order_id);

        if (self.order_map.find(key)) |loc| {
            std.debug.assert(loc.isValid());

            const order = loc.order_ptr;

            // Find and update price level
            if (self.findLevel(loc.side, loc.price)) |level| {
                level.removeOrder(order);
            } else {
                // Order map and level state inconsistent - this is a bug
                std.debug.panic("Order in map but level not found: price={}", .{loc.price});
            }

            // Remove from map
            const removed = self.order_map.remove(key);
            std.debug.assert(removed);

            // Release to pool
            self.pools.order_pool.release(order);

            // Send cancel ack
            _ = output.add(msg.OutputMsg.makeCancelAck(
                user_id,
                user_order_id,
                self.symbol,
                client_id,
            ));

            // Cleanup and update TOB
            self.cleanupEmptyLevels(loc.side);
            self.checkTopOfBookChange(output);
        } else {
            // Order not found
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                user_id,
                user_order_id,
                .order_not_found,
                self.symbol,
                client_id,
            ));
        }

        std.debug.assert(self.isValid());
    }

    /// Cancel all orders for a specific client.
    /// Returns count of orders cancelled.
    pub fn cancelClientOrders(self: *Self, client_id: u32, output: *OutputBuffer) usize {
        std.debug.assert(client_id > 0);
        std.debug.assert(self.isValid());

        var cancelled: usize = 0;

        // Process bids
        cancelled += self.cancelClientOrdersOnSide(&self.bids, self.num_bid_levels, client_id, output);

        // Process asks
        cancelled += self.cancelClientOrdersOnSide(&self.asks, self.num_ask_levels, client_id, output);

        if (cancelled > 0) {
            self.cleanupEmptyLevels(.buy);
            self.cleanupEmptyLevels(.sell);
            self.checkTopOfBookChange(output);
        }

        std.debug.assert(self.isValid());
        return cancelled;
    }

    fn cancelClientOrdersOnSide(
        self: *Self,
        levels: *[MAX_PRICE_LEVELS]PriceLevel,
        num_levels: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) usize {
        var cancelled: usize = 0;

        for (levels[0..num_levels]) |*level| {
            if (!level.active) continue;

            var order = level.orders_head;
            while (order) |o| {
                const next = o.next;

                if (o.client_id == client_id) {
                    level.removeOrder(o);

                    const key = OrderMap.makeKey(o.user_id, o.user_order_id);
                    const removed = self.order_map.remove(key);
                    std.debug.assert(removed);

                    _ = output.add(msg.OutputMsg.makeCancelAck(
                        o.user_id,
                        o.user_order_id,
                        self.symbol,
                        client_id,
                    ));

                    self.pools.order_pool.release(o);
                    cancelled += 1;
                }

                order = next;
            }
        }

        return cancelled;
    }

    // ========================================================================
    // Matching Engine
    // ========================================================================

    fn matchOrder(self: *Self, incoming: *Order, client_id: u32, output: *OutputBuffer) void {
        std.debug.assert(incoming.isValid());
        std.debug.assert(incoming.remaining_qty > 0);

        const opposite_side = incoming.side.opposite();
        var iterations: u32 = 0;

        while (!incoming.isFilled() and iterations < MAX_MATCH_ITERATIONS) {
            const best_level = self.getBestLevel(opposite_side) orelse break;

            // Check if prices cross
            if (!incoming.pricesCross(best_level.price)) {
                break;
            }

            // Match against orders at this level
            var resting = best_level.orders_head;

            while (resting) |rest_order| {
                if (incoming.isFilled() or iterations >= MAX_MATCH_ITERATIONS) break;

                iterations += 1;
                const next = rest_order.next;

                // Calculate fill
                const fill_qty = @min(incoming.remaining_qty, rest_order.remaining_qty);
                const fill_price = rest_order.price;

                std.debug.assert(fill_qty > 0);

                // Execute fill
                const incoming_filled = incoming.fill(fill_qty);
                const resting_filled = rest_order.fill(fill_qty);

                std.debug.assert(incoming_filled == fill_qty);
                std.debug.assert(resting_filled == fill_qty);

                // Update statistics
                self.total_trades += 1;
                self.total_fills += 2; // Both sides filled
                self.volume_traded += fill_qty;

                // Determine buyer/seller for trade messages
                const is_incoming_buyer = (incoming.side == .buy);

                const buyer_uid = if (is_incoming_buyer) incoming.user_id else rest_order.user_id;
                const buyer_oid = if (is_incoming_buyer) incoming.user_order_id else rest_order.user_order_id;
                const buyer_client = if (is_incoming_buyer) client_id else rest_order.client_id;

                const seller_uid = if (!is_incoming_buyer) incoming.user_id else rest_order.user_id;
                const seller_oid = if (!is_incoming_buyer) incoming.user_order_id else rest_order.user_order_id;
                const seller_client = if (!is_incoming_buyer) client_id else rest_order.client_id;

                // Send trade to buyer
                _ = output.add(msg.OutputMsg.makeTrade(
                    buyer_uid,
                    buyer_oid,
                    seller_uid,
                    seller_oid,
                    fill_price,
                    fill_qty,
                    self.symbol,
                    buyer_client,
                ));

                // Send trade to seller
                _ = output.add(msg.OutputMsg.makeTrade(
                    buyer_uid,
                    buyer_oid,
                    seller_uid,
                    seller_oid,
                    fill_price,
                    fill_qty,
                    self.symbol,
                    seller_client,
                ));

                // Handle fully filled resting order
                if (rest_order.isFilled()) {
                    best_level.removeOrder(rest_order);

                    const key = OrderMap.makeKey(rest_order.user_id, rest_order.user_order_id);
                    const removed = self.order_map.remove(key);
                    std.debug.assert(removed);

                    self.pools.order_pool.release(rest_order);
                } else {
                    // Partial fill - update level quantity
                    best_level.reduceQuantity(fill_qty);
                }

                resting = next;
            }

            // Cleanup empty level
            if (!best_level.active or best_level.orders_head == null) {
                self.cleanupEmptyLevels(opposite_side);
            }
        }

        // Warn if we hit iteration limit
        if (iterations >= MAX_MATCH_ITERATIONS) {
            std.log.warn("Match iteration limit reached", .{});
        }
    }

    // ========================================================================
    // Flush
    // ========================================================================

    /// Flush all orders from the book.
    pub fn flush(self: *Self, output: *OutputBuffer) void {
        std.debug.assert(self.isValid());

        // Cancel all bids
        self.flushSide(&self.bids, &self.num_bid_levels, output);

        // Cancel all asks
        self.flushSide(&self.asks, &self.num_ask_levels, output);

        // Clear order map
        self.order_map = OrderMap.init();

        // Emit empty TOB
        _ = output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0));
        _ = output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0));

        self.prev_best_bid_price = 0;
        self.prev_best_bid_qty = 0;
        self.prev_best_ask_price = 0;
        self.prev_best_ask_qty = 0;

        std.debug.assert(self.isValid());
    }

    fn flushSide(
        self: *Self,
        levels: *[MAX_PRICE_LEVELS]PriceLevel,
        num_levels: *u32,
        output: *OutputBuffer,
    ) void {
        for (levels[0..num_levels.*]) |*level| {
            if (!level.active) continue;

            var order = level.orders_head;
            while (order) |o| {
                const next = o.next;

                _ = output.add(msg.OutputMsg.makeCancelAck(
                    o.user_id,
                    o.user_order_id,
                    self.symbol,
                    o.client_id,
                ));

                self.pools.order_pool.release(o);
                order = next;
            }

            level.orders_head = null;
            level.orders_tail = null;
            level.total_quantity = 0;
            level.order_count = 0;
            level.active = false;
        }

        num_levels.* = 0;
    }

    /// Release all orders without sending cancel messages.
    fn releaseAllOrders(self: *Self) void {
        for (self.bids[0..self.num_bid_levels]) |*level| {
            var order = level.orders_head;
            while (order) |o| {
                const next = o.next;
                self.pools.order_pool.release(o);
                order = next;
            }
        }

        for (self.asks[0..self.num_ask_levels]) |*level| {
            var order = level.orders_head;
            while (order) |o| {
                const next = o.next;
                self.pools.order_pool.release(o);
                order = next;
            }
        }
    }

    // ========================================================================
    // Price Level Management
    // ========================================================================

    /// Insert order into book (price level + order map).
    /// Returns true on success, false if book is full.
    fn insertOrder(self: *Self, order: *Order) bool {
        std.debug.assert(order.isValid());
        std.debug.assert(!order.isFilled());

        const key = OrderMap.makeKey(order.user_id, order.user_order_id);

        // Find or create price level
        const level = self.findOrCreateLevel(order.side, order.price) orelse {
            return false; // Book full
        };

        // Add to level
        level.addOrder(order);

        // Add to order map
        const inserted = self.order_map.insert(key, .{
            .side = order.side,
            .price = order.price,
            .order_ptr = order,
        });

        if (!inserted) {
            // Rollback level addition
            level.removeOrder(order);
            return false;
        }

        return true;
    }

    /// Find existing level for price.
    fn findLevel(self: *Self, side: msg.Side, price: u32) ?*PriceLevel {
        const levels = if (side == .buy) &self.bids else &self.asks;
        const count = if (side == .buy) self.num_bid_levels else self.num_ask_levels;

        for (levels[0..count]) |*level| {
            if (level.price == price and level.active) {
                return level;
            }
        }
        return null;
    }

    /// Find or create level for price.
    /// Returns null if book is full.
    fn findOrCreateLevel(self: *Self, side: msg.Side, price: u32) ?*PriceLevel {
        std.debug.assert(price > 0);

        const levels = if (side == .buy) &self.bids else &self.asks;
        const count_ptr = if (side == .buy) &self.num_bid_levels else &self.num_ask_levels;

        // Find insertion point (maintaining sort order)
        var insert_idx: u32 = count_ptr.*;

        for (levels[0..count_ptr.*], 0..) |*level, i| {
            if (level.price == price) {
                // Found existing level
                level.active = true;
                return level;
            }

            // Determine if we should insert here
            const should_insert = if (side == .buy)
                price > level.price // Bids: higher prices first
            else
                price < level.price; // Asks: lower prices first

            if (should_insert) {
                insert_idx = @intCast(i);
                break;
            }
        }

        // Check capacity
        if (count_ptr.* >= MAX_PRICE_LEVELS) {
            std.log.err("Price level capacity exceeded", .{});
            return null;
        }

        // Shift levels to make room
        if (insert_idx < count_ptr.*) {
            var i = count_ptr.*;
            while (i > insert_idx) : (i -= 1) {
                levels[i] = levels[i - 1];
            }
        }

        // Initialize new level
        levels[insert_idx] = PriceLevel.init(price);
        levels[insert_idx].active = true;
        count_ptr.* += 1;

        return &levels[insert_idx];
    }

    /// Get best (first active) level for side.
    fn getBestLevel(self: *Self, side: msg.Side) ?*PriceLevel {
        const levels = if (side == .buy) &self.bids else &self.asks;
        const count = if (side == .buy) self.num_bid_levels else self.num_ask_levels;

        for (levels[0..count]) |*level| {
            if (level.active and level.orders_head != null) {
                return level;
            }
        }
        return null;
    }

    /// Remove empty levels (compaction).
    fn cleanupEmptyLevels(self: *Self, side: msg.Side) void {
        const levels = if (side == .buy) &self.bids else &self.asks;
        const count_ptr = if (side == .buy) &self.num_bid_levels else &self.num_ask_levels;

        var write_idx: u32 = 0;

        for (levels[0..count_ptr.*]) |level| {
            if (level.active and level.orders_head != null) {
                levels[write_idx] = level;
                write_idx += 1;
            }
        }

        count_ptr.* = write_idx;
    }

    // ========================================================================
    // Top of Book
    // ========================================================================

    fn checkTopOfBookChange(self: *Self, output: *OutputBuffer) void {
        // Check best bid
        if (self.getBestLevel(.buy)) |bid| {
            if (bid.price != self.prev_best_bid_price or
                bid.total_quantity != self.prev_best_bid_qty)
            {
                _ = output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .buy,
                    bid.price,
                    bid.total_quantity,
                ));
                self.prev_best_bid_price = bid.price;
                self.prev_best_bid_qty = bid.total_quantity;
            }
        } else if (self.prev_best_bid_price != 0) {
            _ = output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0));
            self.prev_best_bid_price = 0;
            self.prev_best_bid_qty = 0;
        }

        // Check best ask
        if (self.getBestLevel(.sell)) |ask| {
            if (ask.price != self.prev_best_ask_price or
                ask.total_quantity != self.prev_best_ask_qty)
            {
                _ = output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .sell,
                    ask.price,
                    ask.total_quantity,
                ));
                self.prev_best_ask_price = ask.price;
                self.prev_best_ask_qty = ask.total_quantity;
            }
        } else if (self.prev_best_ask_price != 0) {
            _ = output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0));
            self.prev_best_ask_price = 0;
            self.prev_best_ask_qty = 0;
        }
    }

    // ========================================================================
    // Queries
    // ========================================================================

    /// Get best bid price (0 if no bids).
    pub fn getBestBidPrice(self: *const Self) u32 {
        for (self.bids[0..self.num_bid_levels]) |level| {
            if (level.active and level.orders_head != null) {
                return level.price;
            }
        }
        return 0;
    }

    /// Get best ask price (0 if no asks).
    pub fn getBestAskPrice(self: *const Self) u32 {
        for (self.asks[0..self.num_ask_levels]) |level| {
            if (level.active and level.orders_head != null) {
                return level.price;
            }
        }
        return 0;
    }

    /// Get spread (0 if no spread or one side empty).
    pub fn getSpread(self: *const Self) u32 {
        const bid = self.getBestBidPrice();
        const ask = self.getBestAskPrice();

        if (bid == 0 or ask == 0) return 0;
        if (ask <= bid) return 0; // Crossed (shouldn't happen)

        return ask - bid;
    }

    /// Get statistics snapshot.
    pub fn getStats(self: *const Self) OrderBookStats {
        return .{
            .total_orders = self.total_orders,
            .total_cancels = self.total_cancels,
            .total_trades = self.total_trades,
            .total_rejects = self.total_rejects,
            .total_fills = self.total_fills,
            .volume_traded = self.volume_traded,
            .current_bid_levels = self.num_bid_levels,
            .current_ask_levels = self.num_ask_levels,
            .current_orders = self.order_map.count,
            .order_map_load_factor = self.order_map.getLoadFactor(),
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OrderMap basic operations" {
    var map = OrderMap.init();

    const key1 = OrderMap.makeKey(1, 100);
    const key2 = OrderMap.makeKey(2, 200);

    // Create dummy order for location
    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.side = .buy;
    order1.remaining_qty = 10;

    const loc1 = OrderLocation{ .side = .buy, .price = 5000, .order_ptr = &order1 };

    // Insert
    try std.testing.expect(map.insert(key1, loc1));
    try std.testing.expectEqual(@as(u32, 1), map.count);

    // Find
    const found = map.find(key1);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 5000), found.?.price);

    // Not found
    try std.testing.expect(map.find(key2) == null);

    // Remove
    try std.testing.expect(map.remove(key1));
    try std.testing.expectEqual(@as(u32, 0), map.count);
    try std.testing.expectEqual(@as(u32, 1), map.tombstone_count);

    // Find after remove
    try std.testing.expect(map.find(key1) == null);
}

test "PriceLevel order management" {
    var level = PriceLevel.init(5000);

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.remaining_qty = 100;

    var order2 = std.mem.zeroes(Order);
    order2.price = 5000;
    order2.remaining_qty = 50;

    // Add orders
    level.addOrder(&order1);
    try std.testing.expect(level.active);
    try std.testing.expectEqual(@as(u32, 100), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 1), level.order_count);

    level.addOrder(&order2);
    try std.testing.expectEqual(@as(u32, 150), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 2), level.order_count);

    // Verify FIFO order
    try std.testing.expect(level.orders_head == &order1);
    try std.testing.expect(level.orders_tail == &order2);

    // Remove first order
    level.removeOrder(&order1);
    try std.testing.expectEqual(@as(u32, 50), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 1), level.order_count);
    try std.testing.expect(level.orders_head == &order2);

    // Remove last order
    level.removeOrder(&order2);
    try std.testing.expect(!level.active);
    try std.testing.expectEqual(@as(u32, 0), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 0), level.order_count);
}

test "OutputBuffer overflow tracking" {
    var buf = OutputBuffer.init();

    // Fill buffer
    var i: u32 = 0;
    while (i < MAX_OUTPUT_MESSAGES) : (i += 1) {
        try std.testing.expect(buf.add(std.mem.zeroes(msg.OutputMsg)));
    }

    try std.testing.expectEqual(MAX_OUTPUT_MESSAGES, buf.count);
    try std.testing.expect(!buf.hasOverflowed());

    // Overflow
    try std.testing.expect(!buf.add(std.mem.zeroes(msg.OutputMsg)));
    try std.testing.expect(buf.hasOverflowed());
    try std.testing.expectEqual(@as(u64, 1), buf.overflow_count);
}
