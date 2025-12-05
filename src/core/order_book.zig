//! Single-symbol order book with price-time priority matching.
//!
//! Design principles:
//! - Price-time priority: best price first, then FIFO at each level
//! - O(1) order lookup via hash map
//! - O(n) price level operations (acceptable for typical 10-100 levels)
//! - Zero allocation in hot path (uses pre-allocated pools)
//! - Bounded iterations prevent runaway matching
//!
//! Memory model:
//! - Uses initInPlace pattern for large structs to avoid stack overflow
//! - No compile-time array initializers for large arrays
//!
//! Thread Safety:
//! - NOT thread-safe. Single-threaded access only.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const Order = @import("order.zig").Order;
const getCurrentTimestamp = @import("order.zig").getCurrentTimestamp;
const MemoryPools = @import("memory_pool.zig").MemoryPools;

// ============================================================================
// Configuration
// ============================================================================

pub const MAX_PRICE_LEVELS: u32 = 10_000;
pub const MAX_OUTPUT_MESSAGES: u32 = 8_192;
pub const ORDER_MAP_SIZE: u32 = 262_144;
pub const ORDER_MAP_MASK: u32 = ORDER_MAP_SIZE - 1;
pub const MAX_PROBE_LENGTH: u32 = 128;
pub const MAX_MATCH_ITERATIONS: u32 = 200_000;

const TOMBSTONE_COMPACT_THRESHOLD: u32 = 25;
const LOAD_FACTOR_WARNING: u32 = 75;

const HASH_SLOT_EMPTY: u64 = 0;
const HASH_SLOT_TOMBSTONE: u64 = std.math.maxInt(u64);

// ============================================================================
// Order Location
// ============================================================================

pub const OrderLocation = struct {
    side: msg.Side,
    price: u32,
    order_ptr: *Order,

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

pub const OrderMap = struct {
    // NOTE: No default value! Must use initInPlace.
    slots: [ORDER_MAP_SIZE]OrderMapSlot,
    count: u32,
    tombstone_count: u32,
    total_inserts: u64,
    total_removes: u64,
    total_lookups: u64,
    probe_total: u64,
    max_probe: u32,
    compactions: u32,

    const Self = @This();

    /// Initialize in-place (required for large struct).
    pub fn initInPlace(self: *Self) void {
        self.count = 0;
        self.tombstone_count = 0;
        self.total_inserts = 0;
        self.total_removes = 0;
        self.total_lookups = 0;
        self.probe_total = 0;
        self.max_probe = 0;
        self.compactions = 0;

        // Initialize all slots at runtime
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }
    }

    /// Legacy init for small test cases only.
    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    pub inline fn makeKey(user_id: u32, user_order_id: u32) u64 {
        const raw = (@as(u64, user_id) << 32) | user_order_id;
        std.debug.assert(raw != HASH_SLOT_EMPTY);
        std.debug.assert(raw != HASH_SLOT_TOMBSTONE);
        return raw;
    }

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

    pub fn insert(self: *Self, key: u64, location: OrderLocation) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);
        std.debug.assert(location.order_ptr.remaining_qty > 0);

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
                std.debug.assert(self.count <= ORDER_MAP_SIZE);
                return true;
            }

            if (slot_key == key) {
                std.debug.panic("OrderMap.insert: duplicate key {d}", .{key});
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

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

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        self.total_lookups += 1;
        return null;
    }

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

    fn shouldCompact(self: *const Self) bool {
        const threshold = ORDER_MAP_SIZE * TOMBSTONE_COMPACT_THRESHOLD / 100;
        return self.tombstone_count > threshold;
    }

    fn compact(self: *Self) void {
        var entries: [ORDER_MAP_SIZE]OrderMapSlot = undefined;
        var entry_count: u32 = 0;

        for (&self.slots) |*slot| {
            if (slot.key != HASH_SLOT_EMPTY and slot.key != HASH_SLOT_TOMBSTONE) {
                entries[entry_count] = slot.*;
                entry_count += 1;
            }
        }

        std.debug.assert(entry_count == self.count);

        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }

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

    pub fn getLoadFactor(self: *const Self) u32 {
        return (self.count * 100) / ORDER_MAP_SIZE;
    }

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

pub const PriceLevel = extern struct {
    price: u32,
    total_quantity: u32,
    orders_head: ?*Order,
    orders_tail: ?*Order,
    order_count: u32,
    active: bool,
    _padding: [35]u8,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 64);
    }

    const Self = @This();

    pub fn init(price: u32) Self {
        return .{
            .price = price,
            .total_quantity = 0,
            .orders_head = null,
            .orders_tail = null,
            .order_count = 0,
            .active = false,
            ._padding = undefined,
        };
    }

    pub fn isValid(self: *const Self) bool {
        const head_null = (self.orders_head == null);
        const tail_null = (self.orders_tail == null);
        if (head_null != tail_null) return false;
        if (self.active != !head_null) return false;
        if (head_null) {
            if (self.order_count != 0) return false;
            if (self.total_quantity != 0) return false;
        } else {
            if (self.order_count == 0) return false;
        }
        return true;
    }

    pub fn addOrder(self: *Self, order: *Order) void {
        std.debug.assert(order.price == self.price);
        std.debug.assert(order.remaining_qty > 0);
        std.debug.assert(order.next == null);
        std.debug.assert(order.prev == null);

        order.prev = self.orders_tail;

        if (self.orders_tail) |tail| {
            std.debug.assert(tail.next == null);
            tail.next = order;
        } else {
            std.debug.assert(self.orders_head == null);
            self.orders_head = order;
        }

        self.orders_tail = order;
        self.total_quantity += order.remaining_qty;
        self.order_count += 1;
        self.active = true;

        std.debug.assert(self.isValid());
    }

    pub fn removeOrder(self: *Self, order: *Order) void {
        std.debug.assert(self.active);
        std.debug.assert(self.order_count > 0);
        std.debug.assert(order.price == self.price);
        std.debug.assert(self.total_quantity >= order.remaining_qty);

        self.total_quantity -= order.remaining_qty;

        if (order.prev) |prev| {
            prev.next = order.next;
        } else {
            std.debug.assert(self.orders_head == order);
            self.orders_head = order.next;
        }

        if (order.next) |next| {
            next.prev = order.prev;
        } else {
            std.debug.assert(self.orders_tail == order);
            self.orders_tail = order.prev;
        }

        order.next = null;
        order.prev = null;
        self.order_count -= 1;

        if (self.orders_head == null) {
            self.active = false;
            std.debug.assert(self.order_count == 0);
            std.debug.assert(self.total_quantity == 0);
        }

        std.debug.assert(self.isValid());
    }

    pub fn reduceQuantity(self: *Self, amount: u32) void {
        std.debug.assert(self.total_quantity >= amount);
        self.total_quantity -= amount;
    }
};

// ============================================================================
// Output Buffer
// ============================================================================

pub const OutputBuffer = struct {
    // NOTE: No default value! Must use init() or initInPlace().
    messages: [MAX_OUTPUT_MESSAGES]msg.OutputMsg,
    count: u32,
    overflow_count: u64,
    peak_count: u32,

    const Self = @This();

    /// Initialize (small enough to return by value in most cases).
    pub fn init() Self {
        return .{
            .messages = undefined,
            .count = 0,
            .overflow_count = 0,
            .peak_count = 0,
        };
    }

    pub fn hasSpace(self: *const Self, needed: u32) bool {
        return (self.count + needed) <= MAX_OUTPUT_MESSAGES;
    }

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

    pub fn addChecked(self: *Self, message: msg.OutputMsg) void {
        const success = self.add(message);
        std.debug.assert(success);
    }

    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    pub fn slice(self: *const Self) []const msg.OutputMsg {
        return self.messages[0..self.count];
    }

    pub fn hasOverflowed(self: *const Self) bool {
        return self.overflow_count > 0;
    }
};

// ============================================================================
// Order Book Statistics
// ============================================================================

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

pub const OrderBook = struct {
    symbol: msg.Symbol,

    // NOTE: No default values! Must use initInPlace.
    bids: [MAX_PRICE_LEVELS]PriceLevel,
    asks: [MAX_PRICE_LEVELS]PriceLevel,
    num_bid_levels: u32,
    num_ask_levels: u32,

    order_map: OrderMap,

    prev_best_bid_price: u32,
    prev_best_bid_qty: u32,
    prev_best_ask_price: u32,
    prev_best_ask_qty: u32,

    pools: *MemoryPools,

    total_orders: u64,
    total_cancels: u64,
    total_trades: u64,
    total_rejects: u64,
    total_fills: u64,
    volume_traded: u64,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize in-place. For heap-allocated OrderBooks.
    pub fn initInPlace(self: *Self, symbol: msg.Symbol, pools: *MemoryPools) void {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));
        std.debug.assert(pools.order_pool.capacity > 0);

        self.symbol = symbol;
        self.pools = pools;
        self.num_bid_levels = 0;
        self.num_ask_levels = 0;
        self.prev_best_bid_price = 0;
        self.prev_best_bid_qty = 0;
        self.prev_best_ask_price = 0;
        self.prev_best_ask_qty = 0;
        self.total_orders = 0;
        self.total_cancels = 0;
        self.total_trades = 0;
        self.total_rejects = 0;
        self.total_fills = 0;
        self.volume_traded = 0;

        // Initialize order map
        self.order_map.initInPlace();

        // Initialize price levels at runtime (NOT compile-time!)
        for (&self.bids) |*level| {
            level.* = PriceLevel.init(0);
        }
        for (&self.asks) |*level| {
            level.* = PriceLevel.init(0);
        }

        std.debug.assert(self.isValid());
    }

    /// Legacy init - returns by value. Only use for small embedded cases.
    pub fn init(symbol: msg.Symbol, pools: *MemoryPools) Self {
        var book: Self = undefined;
        book.initInPlace(symbol, pools);
        return book;
    }

    pub fn reset(self: *Self, symbol: msg.Symbol) void {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));
        self.releaseAllOrders();
        self.initInPlace(symbol, self.pools);
    }

    fn isValid(self: *const Self) bool {
        if (self.num_bid_levels > MAX_PRICE_LEVELS) return false;
        if (self.num_ask_levels > MAX_PRICE_LEVELS) return false;
        if (!self.order_map.isValid()) return false;
        return true;
    }

    // ========================================================================
    // Order Entry
    // ========================================================================

    pub fn addOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());

        self.total_orders += 1;

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

        const timestamp = getCurrentTimestamp();
        order.* = Order.init(order_msg, client_id, timestamp);

        std.debug.assert(order.isValid());

        _ = output.add(msg.OutputMsg.makeAck(
            order.user_id,
            order.user_order_id,
            self.symbol,
            client_id,
        ));

        self.matchOrder(order, client_id, output);

        if (!order.isFilled()) {
            const inserted = self.insertOrder(order);
            if (!inserted) {
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
            self.pools.order_pool.release(order);
        }

        std.debug.assert(self.isValid());
    }

    // ========================================================================
    // Order Cancellation
    // ========================================================================

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

            if (self.findLevel(loc.side, loc.price)) |level| {
                level.removeOrder(order);
            } else {
                std.debug.panic("Order in map but level not found: price={d}", .{loc.price});
            }

            const removed = self.order_map.remove(key);
            std.debug.assert(removed);

            self.pools.order_pool.release(order);

            _ = output.add(msg.OutputMsg.makeCancelAck(
                user_id,
                user_order_id,
                self.symbol,
                client_id,
            ));

            self.cleanupEmptyLevels(loc.side);
            self.checkTopOfBookChange(output);
        } else {
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

    pub fn cancelClientOrders(self: *Self, client_id: u32, output: *OutputBuffer) usize {
        std.debug.assert(client_id > 0);
        std.debug.assert(self.isValid());

        var cancelled: usize = 0;

        cancelled += self.cancelClientOrdersOnSide(&self.bids, self.num_bid_levels, client_id, output);
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

            if (!incoming.pricesCross(best_level.price)) {
                break;
            }

            var resting = best_level.orders_head;

            while (resting) |rest_order| {
                if (incoming.isFilled() or iterations >= MAX_MATCH_ITERATIONS) break;

                iterations += 1;
                const next = rest_order.next;

                const fill_qty = @min(incoming.remaining_qty, rest_order.remaining_qty);
                const fill_price = rest_order.price;

                std.debug.assert(fill_qty > 0);

                const incoming_filled = incoming.fill(fill_qty);
                const resting_filled = rest_order.fill(fill_qty);

                std.debug.assert(incoming_filled == fill_qty);
                std.debug.assert(resting_filled == fill_qty);

                self.total_trades += 1;
                self.total_fills += 2;
                self.volume_traded += fill_qty;

                const is_incoming_buyer = (incoming.side == .buy);

                const buyer_uid = if (is_incoming_buyer) incoming.user_id else rest_order.user_id;
                const buyer_oid = if (is_incoming_buyer) incoming.user_order_id else rest_order.user_order_id;
                const buyer_client = if (is_incoming_buyer) client_id else rest_order.client_id;

                const seller_uid = if (!is_incoming_buyer) incoming.user_id else rest_order.user_id;
                const seller_oid = if (!is_incoming_buyer) incoming.user_order_id else rest_order.user_order_id;
                const seller_client = if (!is_incoming_buyer) client_id else rest_order.client_id;

                _ = output.add(msg.OutputMsg.makeTrade(
                    buyer_uid, buyer_oid, seller_uid, seller_oid,
                    fill_price, fill_qty, self.symbol, buyer_client,
                ));

                _ = output.add(msg.OutputMsg.makeTrade(
                    buyer_uid, buyer_oid, seller_uid, seller_oid,
                    fill_price, fill_qty, self.symbol, seller_client,
                ));

                if (rest_order.isFilled()) {
                    best_level.removeOrder(rest_order);

                    const key = OrderMap.makeKey(rest_order.user_id, rest_order.user_order_id);
                    const removed = self.order_map.remove(key);
                    std.debug.assert(removed);

                    self.pools.order_pool.release(rest_order);
                } else {
                    best_level.reduceQuantity(fill_qty);
                }

                resting = next;
            }

            if (!best_level.active or best_level.orders_head == null) {
                self.cleanupEmptyLevels(opposite_side);
            }
        }

        if (iterations >= MAX_MATCH_ITERATIONS) {
            std.log.warn("Match iteration limit reached", .{});
        }
    }

    // ========================================================================
    // Flush
    // ========================================================================

    pub fn flush(self: *Self, output: *OutputBuffer) void {
        std.debug.assert(self.isValid());

        self.flushSide(&self.bids, &self.num_bid_levels, output);
        self.flushSide(&self.asks, &self.num_ask_levels, output);

        self.order_map.initInPlace();

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

    fn insertOrder(self: *Self, order: *Order) bool {
        std.debug.assert(order.isValid());
        std.debug.assert(!order.isFilled());

        const key = OrderMap.makeKey(order.user_id, order.user_order_id);

        const level = self.findOrCreateLevel(order.side, order.price) orelse {
            return false;
        };

        level.addOrder(order);

        const inserted = self.order_map.insert(key, .{
            .side = order.side,
            .price = order.price,
            .order_ptr = order,
        });

        if (!inserted) {
            level.removeOrder(order);
            return false;
        }

        return true;
    }

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

    fn findOrCreateLevel(self: *Self, side: msg.Side, price: u32) ?*PriceLevel {
        std.debug.assert(price > 0);

        const levels = if (side == .buy) &self.bids else &self.asks;
        const count_ptr = if (side == .buy) &self.num_bid_levels else &self.num_ask_levels;

        var insert_idx: u32 = count_ptr.*;

        for (levels[0..count_ptr.*], 0..) |*level, i| {
            if (level.price == price) {
                level.active = true;
                return level;
            }

            const should_insert = if (side == .buy)
                price > level.price
            else
                price < level.price;

            if (should_insert) {
                insert_idx = @intCast(i);
                break;
            }
        }

        if (count_ptr.* >= MAX_PRICE_LEVELS) {
            std.log.err("Price level capacity exceeded", .{});
            return null;
        }

        if (insert_idx < count_ptr.*) {
            var i = count_ptr.*;
            while (i > insert_idx) : (i -= 1) {
                levels[i] = levels[i - 1];
            }
        }

        levels[insert_idx] = PriceLevel.init(price);
        levels[insert_idx].active = true;
        count_ptr.* += 1;

        return &levels[insert_idx];
    }

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
        if (self.getBestLevel(.buy)) |bid| {
            if (bid.price != self.prev_best_bid_price or
                bid.total_quantity != self.prev_best_bid_qty)
            {
                _ = output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol, .buy, bid.price, bid.total_quantity,
                ));
                self.prev_best_bid_price = bid.price;
                self.prev_best_bid_qty = bid.total_quantity;
            }
        } else if (self.prev_best_bid_price != 0) {
            _ = output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0));
            self.prev_best_bid_price = 0;
            self.prev_best_bid_qty = 0;
        }

        if (self.getBestLevel(.sell)) |ask| {
            if (ask.price != self.prev_best_ask_price or
                ask.total_quantity != self.prev_best_ask_qty)
            {
                _ = output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol, .sell, ask.price, ask.total_quantity,
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

    pub fn getBestBidPrice(self: *const Self) u32 {
        for (self.bids[0..self.num_bid_levels]) |level| {
            if (level.active and level.orders_head != null) {
                return level.price;
            }
        }
        return 0;
    }

    pub fn getBestAskPrice(self: *const Self) u32 {
        for (self.asks[0..self.num_ask_levels]) |level| {
            if (level.active and level.orders_head != null) {
                return level.price;
            }
        }
        return 0;
    }

    pub fn getSpread(self: *const Self) u32 {
        const bid = self.getBestBidPrice();
        const ask = self.getBestAskPrice();

        if (bid == 0 or ask == 0) return 0;
        if (ask <= bid) return 0;

        return ask - bid;
    }

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

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.side = .buy;
    order1.remaining_qty = 10;

    const loc1 = OrderLocation{ .side = .buy, .price = 5000, .order_ptr = &order1 };

    try std.testing.expect(map.insert(key1, loc1));
    try std.testing.expectEqual(@as(u32, 1), map.count);

    const found = map.find(key1);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 5000), found.?.price);

    try std.testing.expect(map.remove(key1));
    try std.testing.expectEqual(@as(u32, 0), map.count);
}

test "PriceLevel order management" {
    var level = PriceLevel.init(5000);

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.remaining_qty = 100;

    level.addOrder(&order1);
    try std.testing.expect(level.active);
    try std.testing.expectEqual(@as(u32, 100), level.total_quantity);

    level.removeOrder(&order1);
    try std.testing.expect(!level.active);
}

test "OutputBuffer overflow tracking" {
    var buf = OutputBuffer.init();

    var i: u32 = 0;
    while (i < MAX_OUTPUT_MESSAGES) : (i += 1) {
        try std.testing.expect(buf.add(std.mem.zeroes(msg.OutputMsg)));
    }

    try std.testing.expect(!buf.add(std.mem.zeroes(msg.OutputMsg)));
    try std.testing.expect(buf.hasOverflowed());
}
