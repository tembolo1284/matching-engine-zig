//! Single-symbol order book with price-time priority matching.
//!
//! Design principles:
//! - Price-time priority: best price first, then FIFO at each level
//! - O(1) order lookup via OrderMap
//! - O(n) price level operations (acceptable for typical 10-100 levels)
//! - Zero allocation in hot path (uses pre-allocated pools)
//! - Bounded iterations prevent runaway matching (NASA Rule 2)
//! - All output buffer writes are checked (NASA Rule 7)
//! - Functions kept under 60 lines (NASA Rule 4)
//!
//! Output Message Routing:
//! - client_id > 0: unicast to specific TCP client
//! - client_id = 0: multicast to market data feed
//! TopOfBook updates emit TWO messages: one to originator, one to multicast.
//!
//! Thread Safety:
//! - NOT thread-safe. Single-threaded access only.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const Order = @import("order.zig").Order;
const MAX_ORDER_QUANTITY = @import("order.zig").MAX_ORDER_QUANTITY;
const getCurrentTimestamp = @import("order.zig").getCurrentTimestamp;
const MemoryPools = @import("memory_pool.zig").MemoryPools;

// Import from sibling modules
const order_map = @import("order_map.zig");
pub const OrderMap = order_map.OrderMap;
pub const OrderLocation = order_map.OrderLocation;

const output_buffer = @import("output_buffer.zig");
pub const OutputBuffer = output_buffer.OutputBuffer;
pub const MAX_OUTPUT_MESSAGES = output_buffer.MAX_OUTPUT_MESSAGES;

// ============================================================================
// Configuration
// ============================================================================

/// Maximum price levels per side. With O(n) operations, keep this reasonable.
/// For high-frequency scenarios with many price levels, consider a skip list.
///
/// Performance note: With 10,000 levels, worst-case level lookup is O(10000).
/// In practice, most orders trade near best price so typical case is O(10-100).
/// If you need >1000 active levels, consider hash-based level lookup.
pub const MAX_PRICE_LEVELS: u32 = 10_000;

/// Safety bound on matching iterations per incoming order.
/// Prevents runaway matching if book is corrupted.
///
/// Sized for worst case: 200K fills per order (e.g., large order vs many small).
/// If this limit is hit, remaining quantity stays in book (not rejected).
pub const MAX_MATCH_ITERATIONS: u32 = 200_000;

/// Threshold for lazy price level cleanup (number of inactive levels).
/// When exceeded, triggers compaction of empty levels.
///
/// Trade-off: Lower = cleaner book but more frequent cleanup.
/// Higher = less cleanup overhead but more memory/iteration waste.
const LAZY_CLEANUP_THRESHOLD: u32 = 100;

// ============================================================================
// Price Level
// ============================================================================

/// A single price level containing orders at that price.
/// Exactly 64 bytes (one cache line) for optimal memory access.
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

    /// Validate price level invariants.
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

    /// Add order to tail of this price level (FIFO).
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

    /// Remove order from this price level.
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

    /// Reduce total quantity (called during partial fills).
    pub fn reduceQuantity(self: *Self, amount: u32) void {
        std.debug.assert(self.total_quantity >= amount);
        self.total_quantity -= amount;
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
// Fill Result (for extracted fill logic)
// ============================================================================

/// Result of executing a fill between two orders.
const FillResult = struct {
    fill_qty: u32,
    fill_price: u32,
    resting_filled: bool,
};

// ============================================================================
// Order Book
// ============================================================================

pub const OrderBook = struct {
    symbol: msg.Symbol,

    // Price levels (NOTE: No default values! Must use initInPlace)
    bids: [MAX_PRICE_LEVELS]PriceLevel,
    asks: [MAX_PRICE_LEVELS]PriceLevel,
    num_bid_levels: u32,
    num_ask_levels: u32,

    // Count of inactive levels (for lazy cleanup)
    inactive_bid_levels: u32,
    inactive_ask_levels: u32,

    // Order lookup
    order_map: OrderMap,

    // Previous best prices (for TOB change detection)
    prev_best_bid_price: u32,
    prev_best_bid_qty: u32,
    prev_best_ask_price: u32,
    prev_best_ask_qty: u32,

    // Memory pools (external, managed by caller)
    pools: *MemoryPools,

    // Statistics
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
        self.inactive_bid_levels = 0;
        self.inactive_ask_levels = 0;
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

        // Initialize order map with allocator for compaction
        self.order_map.initInPlace(pools.order_pool.allocator);

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

    /// Process a new order.
    ///
    /// Generates: Ack (always), Trade(s) (if matched), TopOfBook (if changed),
    /// or Reject (on error).
    pub fn addOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());
        std.debug.assert(order_msg.quantity <= MAX_ORDER_QUANTITY);

        self.total_orders += 1;

        // Validate order ID is not a reserved sentinel value
        if (!OrderMap.isValidKey(order_msg.user_id, order_msg.user_order_id)) {
            self.total_rejects += 1;
            output.addChecked(msg.OutputMsg.makeReject(
                order_msg.user_id,
                order_msg.user_order_id,
                .invalid_order_id,
                self.symbol,
                client_id,
            ));
            return;
        }

        // Validate quantity
        if (order_msg.quantity == 0) {
            self.total_rejects += 1;
            output.addChecked(msg.OutputMsg.makeReject(
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
            output.addChecked(msg.OutputMsg.makeReject(
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

        // Send acknowledgment
        output.addChecked(msg.OutputMsg.makeAck(
            order.user_id,
            order.user_order_id,
            self.symbol,
            client_id,
        ));

        // Attempt matching
        self.matchOrder(order, client_id, output);

        // If not fully filled, add to book
        if (!order.isFilled()) {
            self.insertOrderOrReject(order, client_id, output);
        } else {
            // Fully filled - release back to pool
            self.checkTopOfBookChange(output, client_id);
            self.pools.order_pool.release(order);
        }

        std.debug.assert(self.isValid());
    }

    /// Insert order into book or reject if book is full.
    fn insertOrderOrReject(
        self: *Self,
        order: *Order,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        const inserted = self.insertOrder(order);
        if (!inserted) {
            std.log.err("Order book full, rejecting order", .{});
            self.total_rejects += 1;
            output.addChecked(msg.OutputMsg.makeReject(
                order.user_id,
                order.user_order_id,
                .book_full,
                self.symbol,
                client_id,
            ));
            self.pools.order_pool.release(order);
            return;
        }
        self.checkTopOfBookChange(output, client_id);
    }

    // ========================================================================
    // Order Cancellation
    // ========================================================================

    /// Cancel an existing order.
    ///
    /// Generates: CancelAck (if found) or Reject (if not found).
    pub fn cancelOrder(
        self: *Self,
        user_id: u32,
        user_order_id: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());

        self.total_cancels += 1;

        // Validate key
        if (!OrderMap.isValidKey(user_id, user_order_id)) {
            self.total_rejects += 1;
            output.addChecked(msg.OutputMsg.makeReject(
                user_id,
                user_order_id,
                .invalid_order_id,
                self.symbol,
                client_id,
            ));
            return;
        }

        const key = OrderMap.makeKey(user_id, user_order_id);

        if (self.order_map.find(key)) |loc| {
            self.executeCancelFound(loc, key, user_id, user_order_id, client_id, output);
        } else {
            self.total_rejects += 1;
            output.addChecked(msg.OutputMsg.makeReject(
                user_id,
                user_order_id,
                .order_not_found,
                self.symbol,
                client_id,
            ));
        }

        std.debug.assert(self.isValid());
    }

    /// Execute cancellation for a found order.
    fn executeCancelFound(
        self: *Self,
        loc: *const OrderLocation,
        key: u64,
        user_id: u32,
        user_order_id: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(loc.isValid());

        const order = loc.order_ptr;

        if (self.findLevel(loc.side, loc.price)) |level| {
            level.removeOrder(order);
            self.markLevelMaybeInactive(loc.side);
        } else {
            std.debug.panic("Order in map but level not found: price={d}", .{loc.price});
        }

        const removed = self.order_map.remove(key);
        std.debug.assert(removed);

        self.pools.order_pool.release(order);

        output.addChecked(msg.OutputMsg.makeCancelAck(
            user_id,
            user_order_id,
            self.symbol,
            client_id,
        ));

        self.maybeCleanupLevels();
        self.checkTopOfBookChange(output, client_id);
    }

    /// Cancel all orders for a specific client (e.g., on disconnect).
    pub fn cancelClientOrders(self: *Self, client_id: u32, output: *OutputBuffer) usize {
        std.debug.assert(client_id > 0);
        std.debug.assert(self.isValid());

        var cancelled: usize = 0;

        cancelled += self.cancelClientOrdersOnSide(&self.bids, self.num_bid_levels, client_id, output);
        cancelled += self.cancelClientOrdersOnSide(&self.asks, self.num_ask_levels, client_id, output);

        if (cancelled > 0) {
            self.maybeCleanupLevels();
            self.checkTopOfBookChange(output, client_id);
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

                    output.addChecked(msg.OutputMsg.makeCancelAck(
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

    /// Match incoming order against resting orders.
    /// Extracted to keep under 60 lines per P10 Rule 4.
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

            self.matchAtLevel(incoming, best_level, client_id, output, &iterations);

            if (!best_level.active or best_level.orders_head == null) {
                self.markLevelMaybeInactive(opposite_side);
            }
        }

        if (iterations >= MAX_MATCH_ITERATIONS) {
            std.log.warn("Match iteration limit reached: {d}", .{iterations});
        }
    }

    /// Match incoming order against orders at a specific price level.
    fn matchAtLevel(
        self: *Self,
        incoming: *Order,
        level: *PriceLevel,
        client_id: u32,
        output: *OutputBuffer,
        iterations: *u32,
    ) void {
        var resting = level.orders_head;

        while (resting) |rest_order| {
            if (incoming.isFilled() or iterations.* >= MAX_MATCH_ITERATIONS) break;

            iterations.* += 1;
            const next = rest_order.next;

            const result = self.executeFill(incoming, rest_order, level, client_id, output);

            if (result.resting_filled) {
                self.removeFilledOrder(rest_order, level);
            }

            resting = next;
        }
    }

    /// Execute a fill between incoming and resting orders.
    /// Returns fill details for caller to handle cleanup.
    fn executeFill(
        self: *Self,
        incoming: *Order,
        resting: *Order,
        level: *PriceLevel,
        client_id: u32,
        output: *OutputBuffer,
    ) FillResult {
        const fill_qty = @min(incoming.remaining_qty, resting.remaining_qty);
        const fill_price = resting.price;

        std.debug.assert(fill_qty > 0);

        const incoming_filled = incoming.fill(fill_qty);
        const resting_filled = resting.fill(fill_qty);

        std.debug.assert(incoming_filled == fill_qty);
        std.debug.assert(resting_filled == fill_qty);

        // Update statistics
        self.total_trades += 1;
        self.total_fills += 2;
        self.volume_traded += fill_qty;
        level.reduceQuantity(fill_qty);

        // Emit trade messages
        self.emitTradeMessages(incoming, resting, fill_price, fill_qty, client_id, output);

        return FillResult{
            .fill_qty = fill_qty,
            .fill_price = fill_price,
            .resting_filled = resting.isFilled(),
        };
    }

    /// Emit trade messages to both parties.
    fn emitTradeMessages(
        self: *Self,
        incoming: *Order,
        resting: *Order,
        fill_price: u32,
        fill_qty: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        const is_incoming_buyer = (incoming.side == .buy);

        const buyer_uid = if (is_incoming_buyer) incoming.user_id else resting.user_id;
        const buyer_oid = if (is_incoming_buyer) incoming.user_order_id else resting.user_order_id;
        const buyer_client = if (is_incoming_buyer) client_id else resting.client_id;

        const seller_uid = if (!is_incoming_buyer) incoming.user_id else resting.user_id;
        const seller_oid = if (!is_incoming_buyer) incoming.user_order_id else resting.user_order_id;
        const seller_client = if (!is_incoming_buyer) client_id else resting.client_id;

        // Trade to buyer (CRITICAL - must not drop)
        output.addChecked(msg.OutputMsg.makeTrade(
            buyer_uid,
            buyer_oid,
            seller_uid,
            seller_oid,
            fill_price,
            fill_qty,
            self.symbol,
            buyer_client,
        ));

        // Trade to seller if different client (CRITICAL - must not drop)
        if (seller_client != buyer_client) {
            output.addChecked(msg.OutputMsg.makeTrade(
                buyer_uid,
                buyer_oid,
                seller_uid,
                seller_oid,
                fill_price,
                fill_qty,
                self.symbol,
                seller_client,
            ));
        }
    }

    /// Remove a fully filled order from level and map.
    fn removeFilledOrder(self: *Self, order: *Order, level: *PriceLevel) void {
        level.removeOrder(order);

        const key = OrderMap.makeKey(order.user_id, order.user_order_id);
        const removed = self.order_map.remove(key);
        std.debug.assert(removed);

        self.pools.order_pool.release(order);
    }

    // ========================================================================
    // Flush
    // ========================================================================

    /// Remove all orders from the book.
    ///
    /// Generates: CancelAck for each order, TopOfBook (empty) for both sides.
    pub fn flush(self: *Self, output: *OutputBuffer, client_id: u32) void {
        std.debug.assert(self.isValid());

        self.flushSide(&self.bids, &self.num_bid_levels, output);
        self.flushSide(&self.asks, &self.num_ask_levels, output);

        self.order_map.initInPlace(self.pools.order_pool.allocator);
        self.inactive_bid_levels = 0;
        self.inactive_ask_levels = 0;

        // Emit empty book state
        // - client_id: to originator
        // - 0: to multicast feed
        output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0, client_id));
        output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0, 0));
        output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0, client_id));
        output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0, 0));

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

                output.addChecked(msg.OutputMsg.makeCancelAck(
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

        // Shift levels to make room (O(n) but rare for well-distributed prices)
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

    /// Mark that a side may have inactive levels (for lazy cleanup).
    fn markLevelMaybeInactive(self: *Self, side: msg.Side) void {
        if (side == .buy) {
            self.inactive_bid_levels += 1;
        } else {
            self.inactive_ask_levels += 1;
        }
    }

    /// Perform lazy cleanup if inactive level count exceeds threshold.
    fn maybeCleanupLevels(self: *Self) void {
        if (self.inactive_bid_levels > LAZY_CLEANUP_THRESHOLD) {
            self.cleanupEmptyLevels(.buy);
            self.inactive_bid_levels = 0;
        }
        if (self.inactive_ask_levels > LAZY_CLEANUP_THRESHOLD) {
            self.cleanupEmptyLevels(.sell);
            self.inactive_ask_levels = 0;
        }
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

    /// Check if best bid/ask changed and emit TopOfBook updates.
    ///
    /// Emits TWO messages per side when changed:
    /// - One to client_id (originator of the action)
    /// - One to client_id=0 (multicast market data feed)
    fn checkTopOfBookChange(self: *Self, output: *OutputBuffer, client_id: u32) void {
        self.checkBidTopOfBook(output, client_id);
        self.checkAskTopOfBook(output, client_id);
    }

    fn checkBidTopOfBook(self: *Self, output: *OutputBuffer, client_id: u32) void {
        if (self.getBestLevel(.buy)) |bid| {
            if (bid.price != self.prev_best_bid_price or
                bid.total_quantity != self.prev_best_bid_qty)
            {
                output.addChecked(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .buy,
                    bid.price,
                    bid.total_quantity,
                    client_id,
                ));
                output.addChecked(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .buy,
                    bid.price,
                    bid.total_quantity,
                    0,
                ));
                self.prev_best_bid_price = bid.price;
                self.prev_best_bid_qty = bid.total_quantity;
            }
        } else if (self.prev_best_bid_price != 0) {
            output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0, client_id));
            output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0, 0));
            self.prev_best_bid_price = 0;
            self.prev_best_bid_qty = 0;
        }
    }

    fn checkAskTopOfBook(self: *Self, output: *OutputBuffer, client_id: u32) void {
        if (self.getBestLevel(.sell)) |ask| {
            if (ask.price != self.prev_best_ask_price or
                ask.total_quantity != self.prev_best_ask_qty)
            {
                output.addChecked(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .sell,
                    ask.price,
                    ask.total_quantity,
                    client_id,
                ));
                output.addChecked(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .sell,
                    ask.price,
                    ask.total_quantity,
                    0,
                ));
                self.prev_best_ask_price = ask.price;
                self.prev_best_ask_qty = ask.total_quantity;
            }
        } else if (self.prev_best_ask_price != 0) {
            output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0, client_id));
            output.addChecked(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0, 0));
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

test "PriceLevel basic operations" {
    var level = PriceLevel.init(5000);

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.remaining_qty = 100;

    level.addOrder(&order1);
    try std.testing.expect(level.active);
    try std.testing.expectEqual(@as(u32, 100), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 1), level.order_count);

    level.removeOrder(&order1);
    try std.testing.expect(!level.active);
    try std.testing.expectEqual(@as(u32, 0), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 0), level.order_count);
}

test "PriceLevel FIFO ordering" {
    var level = PriceLevel.init(5000);

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.remaining_qty = 10;
    order1.user_id = 1;

    var order2 = std.mem.zeroes(Order);
    order2.price = 5000;
    order2.remaining_qty = 20;
    order2.user_id = 2;

    var order3 = std.mem.zeroes(Order);
    order3.price = 5000;
    order3.remaining_qty = 30;
    order3.user_id = 3;

    level.addOrder(&order1);
    level.addOrder(&order2);
    level.addOrder(&order3);

    // Head should be first order (oldest)
    try std.testing.expectEqual(@as(u32, 1), level.orders_head.?.user_id);
    // Tail should be last order (newest)
    try std.testing.expectEqual(@as(u32, 3), level.orders_tail.?.user_id);

    try std.testing.expectEqual(@as(u32, 60), level.total_quantity);
    try std.testing.expectEqual(@as(u32, 3), level.order_count);
}

test "PriceLevel reduce quantity" {
    var level = PriceLevel.init(5000);

    var order = std.mem.zeroes(Order);
    order.price = 5000;
    order.remaining_qty = 100;

    level.addOrder(&order);
    try std.testing.expectEqual(@as(u32, 100), level.total_quantity);

    level.reduceQuantity(30);
    try std.testing.expectEqual(@as(u32, 70), level.total_quantity);
}
