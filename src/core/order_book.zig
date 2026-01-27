//! OrderBook - Single Symbol Order Book with Price-Time Priority
//!
//! Design principles (Power of Ten + cache optimization):
//! - No dynamic allocation after init (Rule 3)
//! - All loops have fixed upper bounds (Rule 2)
//! - Minimum 2 assertions per function (Rule 5)
//! - Open-addressing hash table for cache-friendly lookups
//! - Cache-line aligned orders to prevent false sharing
//! - Pre-allocated memory pools

const std = @import("std");
const Order = @import("order.zig").Order;
const OrderType = @import("order.zig").OrderType;
const getCurrentTimestamp = @import("order.zig").getCurrentTimestamp;
const msg = @import("../protocol/message_types.zig");
const OutputBuffer = @import("output_buffer.zig").OutputBuffer;

// ============================================================================
// Configuration Constants
// ============================================================================

/// Maximum price levels we can handle
pub const MAX_PRICE_LEVELS: u32 = 512;

/// Maximum orders per price level (for capacity planning)
pub const TYPICAL_ORDERS_PER_LEVEL: u32 = 20;

/// Number of orders to process per flush iteration
pub const FLUSH_BATCH_SIZE: u32 = 4096;

/// Hash table size - MUST be power of 2 for fast masking
pub const ORDER_MAP_SIZE: u32 = 16384;
const ORDER_MAP_MASK: u32 = ORDER_MAP_SIZE - 1;

// Compile-time verification that size is power of 2
comptime {
    std.debug.assert((ORDER_MAP_SIZE & (ORDER_MAP_SIZE - 1)) == 0);
}

/// Maximum probe length for open-addressing (Rule 2 compliance)
pub const MAX_PROBE_LENGTH: u32 = 128;

/// Maximum iterations for matching loops (Rule 2 compliance)
pub const MAX_MATCH_ITERATIONS: u32 = MAX_PRICE_LEVELS * TYPICAL_ORDERS_PER_LEVEL;
pub const MAX_ORDERS_AT_PRICE_LEVEL: u32 = TYPICAL_ORDERS_PER_LEVEL * 10;

/// Memory pool size
pub const MAX_ORDERS_IN_POOL: u32 = 8192;

/// Sentinel values for open-addressing hash table
pub const HASH_SLOT_EMPTY: u64 = 0;
pub const HASH_SLOT_TOMBSTONE: u64 = std.math.maxInt(u64);

// ============================================================================
// Price Level Structure
// ============================================================================

/// Price level - holds orders at a specific price
/// Aligned to 64 bytes to avoid false sharing between adjacent levels
pub const PriceLevel = extern struct {
    price: u32, // Price for this level
    total_quantity: u32, // Sum of remaining_qty for all orders
    orders_head: ?*Order, // First order (oldest, highest time priority)
    orders_tail: ?*Order, // Last order (newest)
    active: bool, // True if level has orders
    _pad: [39]u8, // Explicit padding to 64 bytes

    const Self = @This();

    comptime {
        std.debug.assert(@sizeOf(PriceLevel) == 64);
    }

    pub fn init() Self {
        return Self{
            .price = 0,
            .total_quantity = 0,
            .orders_head = null,
            .orders_tail = null,
            .active = false,
            ._pad = [_]u8{0} ** 39,
        };
    }

    pub fn reset(self: *Self) void {
        self.price = 0;
        self.total_quantity = 0;
        self.orders_head = null;
        self.orders_tail = null;
        self.active = false;
    }
};

// ============================================================================
// Order Location for Cancellation Lookup
// ============================================================================

pub const OrderLocation = struct {
    side: msg.Side,
    price: u32,
    order_ptr: *Order,
};

// ============================================================================
// Open-Addressing Hash Table
// ============================================================================

pub const OrderMapSlot = struct {
    key: u64, // Combined user_id + user_order_id
    location: OrderLocation,
};

pub const OrderMap = struct {
    slots: [ORDER_MAP_SIZE]OrderMapSlot,
    count: u32,
    tombstone_count: u32,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .slots = undefined,
            .count = 0,
            .tombstone_count = 0,
        };
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }
        return self;
    }

    pub fn clear(self: *Self) void {
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }
        self.count = 0;
        self.tombstone_count = 0;

        std.debug.assert(self.count == 0); // Rule 5
    }

    pub fn insert(self: *Self, key: u64, location: *const OrderLocation) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY); // Rule 5
        std.debug.assert(key != HASH_SLOT_TOMBSTONE); // Rule 5

        const hash = hashOrderKey(key);

        // Rule 2: Bounded probe sequence
        var i: u32 = 0;
        while (i < MAX_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & ORDER_MAP_MASK;
            const slot = &self.slots[idx];

            // Found empty or tombstone slot - insert here
            if (slot.key == HASH_SLOT_EMPTY or slot.key == HASH_SLOT_TOMBSTONE) {
                if (slot.key == HASH_SLOT_TOMBSTONE) {
                    self.tombstone_count -= 1;
                }
                slot.key = key;
                slot.location = location.*;
                self.count += 1;
                return true;
            }

            // Key already exists - update
            if (slot.key == key) {
                slot.location = location.*;
                return true;
            }
        }

        return false; // Table full
    }

    pub fn find(self: *Self, key: u64) ?*OrderMapSlot {
        std.debug.assert(self.count <= ORDER_MAP_SIZE); // Rule 5

        if (key == HASH_SLOT_EMPTY or key == HASH_SLOT_TOMBSTONE) {
            return null;
        }

        const hash = hashOrderKey(key);

        // Rule 2: Bounded probe sequence
        var i: u32 = 0;
        while (i < MAX_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & ORDER_MAP_MASK;
            const slot = &self.slots[idx];

            if (slot.key == key) {
                return slot;
            }

            if (slot.key == HASH_SLOT_EMPTY) {
                return null;
            }
            // Tombstone - keep probing
        }

        return null;
    }

    pub fn remove(self: *Self, key: u64) bool {
        std.debug.assert(self.count <= ORDER_MAP_SIZE); // Rule 5

        if (self.find(key)) |slot| {
            slot.key = HASH_SLOT_TOMBSTONE;
            self.count -= 1;
            self.tombstone_count += 1;
            return true;
        }
        return false;
    }
};

// ============================================================================
// Memory Pool
// ============================================================================

pub const OrderPool = struct {
    orders: [MAX_ORDERS_IN_POOL]Order align(64),
    free_list: [MAX_ORDERS_IN_POOL]u32,
    free_count: u32,
    total_allocations: u32,
    peak_usage: u32,
    allocation_failures: u32,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .orders = undefined,
            .free_list = undefined,
            .free_count = MAX_ORDERS_IN_POOL,
            .total_allocations = 0,
            .peak_usage = 0,
            .allocation_failures = 0,
        };

        // Initialize free list (all indices available)
        for (0..MAX_ORDERS_IN_POOL) |i| {
            self.free_list[i] = @intCast(i);
        }

        std.debug.assert(self.free_count == MAX_ORDERS_IN_POOL); // Rule 5
        return self;
    }

    /// Allocate order from pool
    /// Performance: O(1), ~5-10 CPU cycles
    pub fn alloc(self: *Self) ?*Order {
        std.debug.assert(self.free_count <= MAX_ORDERS_IN_POOL); // Rule 5

        if (self.free_count == 0) {
            self.allocation_failures += 1;
            return null;
        }

        self.free_count -= 1;
        const index = self.free_list[self.free_count];

        std.debug.assert(index < MAX_ORDERS_IN_POOL); // Rule 5

        self.total_allocations += 1;
        const current_usage = MAX_ORDERS_IN_POOL - self.free_count;
        if (current_usage > self.peak_usage) {
            self.peak_usage = current_usage;
        }

        return &self.orders[index];
    }

    /// Free order back to pool
    /// Performance: O(1), ~5-10 CPU cycles
    pub fn free(self: *Self, order: *Order) void {
        std.debug.assert(self.free_count < MAX_ORDERS_IN_POOL); // Rule 5

        // Calculate index from pointer
        const base = @intFromPtr(&self.orders[0]);
        const ptr = @intFromPtr(order);
        const index: u32 = @intCast((ptr - base) / @sizeOf(Order));

        std.debug.assert(index < MAX_ORDERS_IN_POOL); // Rule 5

        self.free_list[self.free_count] = index;
        self.free_count += 1;
    }
};

// ============================================================================
// Flush State
// ============================================================================

pub const FlushState = struct {
    current_order: ?*Order,
    current_bid_level: u32,
    current_ask_level: u32,
    in_progress: bool,
    processing_bids: bool,
    bids_done: bool,
    asks_done: bool,

    pub fn init() FlushState {
        return FlushState{
            .current_order = null,
            .current_bid_level = 0,
            .current_ask_level = 0,
            .in_progress = false,
            .processing_bids = true,
            .bids_done = false,
            .asks_done = false,
        };
    }

    pub fn reset(self: *FlushState) void {
        self.* = FlushState.init();
    }
};

// ============================================================================
// Order Book Structure
// ============================================================================

pub const OrderBook = struct {
    symbol: msg.Symbol,

    // Price levels - fixed arrays, sorted by price
    bids: [MAX_PRICE_LEVELS]PriceLevel, // Descending price order
    asks: [MAX_PRICE_LEVELS]PriceLevel, // Ascending price order
    num_bid_levels: u32,
    num_ask_levels: u32,

    // Order lookup - open-addressing hash table
    order_map: OrderMap,

    // Track previous best bid/ask for TOB change detection
    prev_best_bid_price: u32,
    prev_best_bid_qty: u32,
    prev_best_ask_price: u32,
    prev_best_ask_qty: u32,

    // Track if sides ever had orders (for TOB eliminated messages)
    bid_side_ever_active: bool,
    ask_side_ever_active: bool,

    // Flush state for iterative flushing
    flush_state: FlushState,

    // Memory pool (owned)
    pool: OrderPool,

    const Self = @This();

    pub fn init(symbol: []const u8) Self {
        std.debug.assert(symbol.len > 0); // Rule 5
        std.debug.assert(symbol.len < msg.MAX_SYMBOL_LENGTH); // Rule 5

        var self = Self{
            .symbol = undefined,
            .bids = undefined,
            .asks = undefined,
            .num_bid_levels = 0,
            .num_ask_levels = 0,
            .order_map = OrderMap.init(),
            .prev_best_bid_price = 0,
            .prev_best_bid_qty = 0,
            .prev_best_ask_price = 0,
            .prev_best_ask_qty = 0,
            .bid_side_ever_active = false,
            .ask_side_ever_active = false,
            .flush_state = FlushState.init(),
            .pool = OrderPool.init(),
        };

        msg.copySymbol(&self.symbol, symbol);

        // Initialize price levels
        for (&self.bids) |*level| {
            level.* = PriceLevel.init();
        }
        for (&self.asks) |*level| {
            level.* = PriceLevel.init();
        }

        return self;
    }

    // ========================================================================
    // Public API
    // ========================================================================

    /// Process new order
    pub fn addOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(order_msg.quantity > 0); // Rule 5

        // Allocate from pool
        const order = self.pool.alloc() orelse {
            // Pool exhausted - just send ack and return
            output.addAck(msg.symbolSlice(&self.symbol), order_msg.user_id, order_msg.user_order_id);
            return;
        };

        // Initialize order
        const timestamp = getCurrentTimestamp();
        order.init(order_msg, timestamp);
        order.client_id = client_id;

        // Send acknowledgement
        output.addAck(msg.symbolSlice(&self.symbol), order.user_id, order.user_order_id);

        // Try to match the order
        self.matchOrder(order, output);

        // If order has remaining quantity and is a limit order, add to book
        if (order.remaining_qty > 0 and order.order_type == .limit) {
            self.addToBook(order);
        } else {
            // Order fully filled or market order - return to pool
            self.pool.free(order);
        }
    }

    /// Cancel order
    pub fn cancelOrder(
        self: *Self,
        user_id: u32,
        user_order_id: u32,
        output: *OutputBuffer,
    ) void {
        const key = makeOrderKey(user_id, user_order_id);
        const slot = self.order_map.find(key);

        if (slot == null) {
            // Order not found - still send cancel ack
            output.addCancelAck(msg.symbolSlice(&self.symbol), user_id, user_order_id);
            return;
        }

        const loc = &slot.?.location;
        const order = loc.order_ptr;

        // Find price level
        const levels = if (loc.side == .buy) &self.bids else &self.asks;
        const num_levels = if (loc.side == .buy) &self.num_bid_levels else &self.num_ask_levels;
        const descending = (loc.side == .buy);

        const idx = self.findPriceLevel(levels, num_levels.*, loc.price, descending);
        if (idx) |level_idx| {
            const level = &levels[level_idx];

            // Update total quantity
            level.total_quantity -= order.remaining_qty;

            // Remove from list
            self.listRemove(&level.orders_head, &level.orders_tail, order);

            // Return to pool
            self.pool.free(order);

            // Remove price level if empty
            if (level.orders_head == null) {
                self.removePriceLevel(levels, num_levels, level_idx);
            }
        }

        // Remove from order map
        _ = self.order_map.remove(key);

        // Send cancel acknowledgement
        output.addCancelAck(msg.symbolSlice(&self.symbol), user_id, user_order_id);
    }

    /// Cancel all orders for a specific client
    pub fn cancelClientOrders(
        self: *Self,
        client_id: u32,
        output: *OutputBuffer,
    ) usize {
        // Phase 1: Collect keys to cancel (avoids iterator invalidation)
        var to_cancel: [MAX_ORDERS_IN_POOL]struct { user_id: u32, user_order_id: u32 } = undefined;
        var cancel_count: u32 = 0;

        // Scan bid levels
        for (self.bids[0..self.num_bid_levels]) |*level| {
            var order = level.orders_head;
            var order_count: u32 = 0;
            while (order != null and order_count < MAX_ORDERS_AT_PRICE_LEVEL) : (order_count += 1) {
                if (order.?.client_id == client_id and cancel_count < MAX_ORDERS_IN_POOL) {
                    to_cancel[cancel_count] = .{
                        .user_id = order.?.user_id,
                        .user_order_id = order.?.user_order_id,
                    };
                    cancel_count += 1;
                }
                order = order.?.next;
            }
        }

        // Scan ask levels
        for (self.asks[0..self.num_ask_levels]) |*level| {
            var order = level.orders_head;
            var order_count: u32 = 0;
            while (order != null and order_count < MAX_ORDERS_AT_PRICE_LEVEL) : (order_count += 1) {
                if (order.?.client_id == client_id and cancel_count < MAX_ORDERS_IN_POOL) {
                    to_cancel[cancel_count] = .{
                        .user_id = order.?.user_id,
                        .user_order_id = order.?.user_order_id,
                    };
                    cancel_count += 1;
                }
                order = order.?.next;
            }
        }

        // Phase 2: Cancel collected orders
        for (to_cancel[0..cancel_count]) |item| {
            self.cancelOrder(item.user_id, item.user_order_id, output);
        }

        return cancel_count;
    }

    /// Flush order book - iterative version
    /// Returns true when flush is complete
    pub fn flush(self: *Self, output: *OutputBuffer) bool {
        const state = &self.flush_state;

        // Initialize flush state on first call
        if (!state.in_progress) {
            state.in_progress = true;
            state.current_bid_level = 0;
            state.current_ask_level = 0;
            state.current_order = null;
            state.processing_bids = true;
            state.bids_done = false;
            state.asks_done = false;
        }

        var remaining_budget = FLUSH_BATCH_SIZE;

        // Process bids
        if (!state.bids_done) {
            const processed = self.flushProcessSide(
                &self.bids,
                self.num_bid_levels,
                &state.current_bid_level,
                &state.current_order,
                &state.bids_done,
                remaining_budget,
                output,
            );
            remaining_budget -= processed;

            if (state.bids_done) {
                state.current_order = null;
            }
        }

        // Process asks
        if (!state.asks_done and remaining_budget > 0) {
            _ = self.flushProcessSide(
                &self.asks,
                self.num_ask_levels,
                &state.current_ask_level,
                &state.current_order,
                &state.asks_done,
                remaining_budget,
                output,
            );
        }

        // Check if flush is complete
        if (state.bids_done and state.asks_done) {
            self.flushFinalize(output);
            return true;
        }

        return false;
    }

    /// Check if flush is in progress
    pub fn flushInProgress(self: *const Self) bool {
        return self.flush_state.in_progress;
    }

    /// Reset flush state
    pub fn flushReset(self: *Self) void {
        self.flush_state.reset();
        std.debug.assert(!self.flush_state.in_progress); // Rule 5
    }

    /// Get best bid price
    pub fn getBestBidPrice(self: *const Self) u32 {
        std.debug.assert(self.num_bid_levels <= MAX_PRICE_LEVELS); // Rule 5
        return if (self.num_bid_levels > 0) self.bids[0].price else 0;
    }

    /// Get best ask price
    pub fn getBestAskPrice(self: *const Self) u32 {
        std.debug.assert(self.num_ask_levels <= MAX_PRICE_LEVELS); // Rule 5
        return if (self.num_ask_levels > 0) self.asks[0].price else 0;
    }

    /// Get best bid quantity
    pub fn getBestBidQuantity(self: *const Self) u32 {
        std.debug.assert(self.num_bid_levels <= MAX_PRICE_LEVELS); // Rule 5
        return if (self.num_bid_levels > 0) self.bids[0].total_quantity else 0;
    }

    /// Get best ask quantity
    pub fn getBestAskQuantity(self: *const Self) u32 {
        std.debug.assert(self.num_ask_levels <= MAX_PRICE_LEVELS); // Rule 5
        return if (self.num_ask_levels > 0) self.asks[0].total_quantity else 0;
    }

    /// Generate TOB messages for current state (explicit TOB request)
    pub fn generateTopOfBook(self: *Self, output: *OutputBuffer) void {
        const symbol = msg.symbolSlice(&self.symbol);

        // Generate bid TOB
        if (self.num_bid_levels > 0) {
            output.addTopOfBook(symbol, .buy, self.bids[0].price, self.bids[0].total_quantity);
        } else if (self.bid_side_ever_active) {
            output.addTopOfBookEliminated(symbol, .buy);
        }

        // Generate ask TOB
        if (self.num_ask_levels > 0) {
            output.addTopOfBook(symbol, .sell, self.asks[0].price, self.asks[0].total_quantity);
        } else if (self.ask_side_ever_active) {
            output.addTopOfBookEliminated(symbol, .sell);
        }
    }

    // ========================================================================
    // Private Implementation
    // ========================================================================

    fn matchOrder(self: *Self, order: *Order, output: *OutputBuffer) void {
        if (order.side == .buy) {
            self.matchBuyOrder(order, output);
        } else {
            self.matchSellOrder(order, output);
        }
    }

    fn matchBuyOrder(self: *Self, order: *Order, output: *OutputBuffer) void {
        std.debug.assert(order.side == .buy); // Rule 5

        var iteration_count: u32 = 0;

        while (order.remaining_qty > 0 and
            self.num_ask_levels > 0 and
            iteration_count < MAX_MATCH_ITERATIONS)
        {
            iteration_count += 1;

            const best_ask_level = &self.asks[0];

            // Check if we can match at this price
            const can_match = (order.order_type == .market) or
                (order.price >= best_ask_level.price);

            if (!can_match) break;

            // Match with orders at this price level (FIFO)
            var passive_order = best_ask_level.orders_head;
            var inner_iteration: u32 = 0;

            while (order.remaining_qty > 0 and
                passive_order != null and
                inner_iteration < MAX_ORDERS_AT_PRICE_LEVEL)
            {
                inner_iteration += 1;

                const next_order = passive_order.?.next;
                _ = self.executeTrade(order, passive_order.?, best_ask_level, best_ask_level.price, output);
                passive_order = next_order;
            }

            // Remove price level if empty
            if (best_ask_level.orders_head == null) {
                self.removePriceLevel(&self.asks, &self.num_ask_levels, 0);
            }
        }

        std.debug.assert(iteration_count < MAX_MATCH_ITERATIONS); // Rule 5
    }

    fn matchSellOrder(self: *Self, order: *Order, output: *OutputBuffer) void {
        std.debug.assert(order.side == .sell); // Rule 5

        var iteration_count: u32 = 0;

        while (order.remaining_qty > 0 and
            self.num_bid_levels > 0 and
            iteration_count < MAX_MATCH_ITERATIONS)
        {
            iteration_count += 1;

            const best_bid_level = &self.bids[0];

            // Check if we can match at this price
            const can_match = (order.order_type == .market) or
                (order.price <= best_bid_level.price);

            if (!can_match) break;

            // Match with orders at this price level (FIFO)
            var passive_order = best_bid_level.orders_head;
            var inner_iteration: u32 = 0;

            while (order.remaining_qty > 0 and
                passive_order != null and
                inner_iteration < MAX_ORDERS_AT_PRICE_LEVEL)
            {
                inner_iteration += 1;

                const next_order = passive_order.?.next;
                _ = self.executeTrade(order, passive_order.?, best_bid_level, best_bid_level.price, output);
                passive_order = next_order;
            }

            // Remove price level if empty
            if (best_bid_level.orders_head == null) {
                self.removePriceLevel(&self.bids, &self.num_bid_levels, 0);
            }
        }

        std.debug.assert(iteration_count < MAX_MATCH_ITERATIONS); // Rule 5
    }

    fn executeTrade(
        self: *Self,
        aggressor: *Order,
        passive: *Order,
        level: *PriceLevel,
        trade_price: u32,
        output: *OutputBuffer,
    ) bool {
        std.debug.assert(aggressor.remaining_qty > 0); // Rule 5
        std.debug.assert(passive.remaining_qty > 0); // Rule 5

        const trade_qty = @min(aggressor.remaining_qty, passive.remaining_qty);

        // Determine buy/sell sides
        var buy_user_id: u32 = undefined;
        var buy_order_id: u32 = undefined;
        var buy_client_id: u32 = undefined;
        var sell_user_id: u32 = undefined;
        var sell_order_id: u32 = undefined;
        var sell_client_id: u32 = undefined;

        if (aggressor.side == .buy) {
            buy_user_id = aggressor.user_id;
            buy_order_id = aggressor.user_order_id;
            buy_client_id = aggressor.client_id;
            sell_user_id = passive.user_id;
            sell_order_id = passive.user_order_id;
            sell_client_id = passive.client_id;
        } else {
            buy_user_id = passive.user_id;
            buy_order_id = passive.user_order_id;
            buy_client_id = passive.client_id;
            sell_user_id = aggressor.user_id;
            sell_order_id = aggressor.user_order_id;
            sell_client_id = aggressor.client_id;
        }

        // Generate trade message
        output.addTradeWithClients(
            msg.symbolSlice(&self.symbol),
            buy_user_id,
            buy_order_id,
            buy_client_id,
            sell_user_id,
            sell_order_id,
            sell_client_id,
            trade_price,
            trade_qty,
        );

        // Update quantities
        _ = aggressor.fill(trade_qty);
        _ = passive.fill(trade_qty);
        level.total_quantity -= trade_qty;

        // Check if passive order is fully filled
        const passive_filled = passive.isFilled();
        if (passive_filled) {
            const key = makeOrderKey(passive.user_id, passive.user_order_id);
            _ = self.order_map.remove(key);
            self.listRemove(&level.orders_head, &level.orders_tail, passive);
            self.pool.free(passive);
        }

        return passive_filled;
    }

    fn addToBook(self: *Self, order: *Order) void {
        std.debug.assert(order.order_type == .limit); // Rule 5
        std.debug.assert(order.price > 0); // Rule 5

        if (order.side == .buy) {
            self.bid_side_ever_active = true;
            var idx = self.findPriceLevel(&self.bids, self.num_bid_levels, order.price, true);
            if (idx == null) {
                idx = self.insertPriceLevel(&self.bids, &self.num_bid_levels, order.price, true);
            }
            self.addOrderToLevel(&self.bids[idx.?], order);
        } else {
            self.ask_side_ever_active = true;
            var idx = self.findPriceLevel(&self.asks, self.num_ask_levels, order.price, false);
            if (idx == null) {
                idx = self.insertPriceLevel(&self.asks, &self.num_ask_levels, order.price, false);
            }
            self.addOrderToLevel(&self.asks[idx.?], order);
        }
    }

    fn addOrderToLevel(self: *Self, level: *PriceLevel, order: *Order) void {
        // Add to list
        self.listAppend(&level.orders_head, &level.orders_tail, order);

        // Update total quantity
        level.total_quantity += order.remaining_qty;

        // Add to order map
        const key = makeOrderKey(order.user_id, order.user_order_id);
        const location = OrderLocation{
            .side = order.side,
            .price = order.price,
            .order_ptr = order,
        };
        _ = self.order_map.insert(key, &location);
    }

    fn findPriceLevel(
        self: *const Self,
        levels: *const [MAX_PRICE_LEVELS]PriceLevel,
        num_levels: u32,
        price: u32,
        descending: bool,
    ) ?u32 {
        _ = self;
        std.debug.assert(num_levels <= MAX_PRICE_LEVELS); // Rule 5

        if (num_levels == 0) return null;

        var left: i32 = 0;
        var right: i32 = @as(i32, @intCast(num_levels)) - 1;

        while (left <= right) {
            const mid = @divFloor(left + right, 2);
            const mid_idx: u32 = @intCast(mid);

            if (levels[mid_idx].price == price) {
                return mid_idx;
            }

            if (descending) {
                if (levels[mid_idx].price > price) {
                    left = mid + 1;
                } else {
                    right = mid - 1;
                }
            } else {
                if (levels[mid_idx].price < price) {
                    left = mid + 1;
                } else {
                    right = mid - 1;
                }
            }
        }

        return null;
    }

    fn insertPriceLevel(
        self: *Self,
        levels: *[MAX_PRICE_LEVELS]PriceLevel,
        num_levels: *u32,
        price: u32,
        descending: bool,
    ) u32 {
        _ = self;
        std.debug.assert(num_levels.* < MAX_PRICE_LEVELS); // Rule 5

        // Find insertion position
        var insert_pos = num_levels.*;
        for (0..num_levels.*) |i| {
            const should_insert = if (descending)
                price > levels[i].price
            else
                price < levels[i].price;

            if (should_insert) {
                insert_pos = @intCast(i);
                break;
            }
        }

        // Shift elements
        if (insert_pos < num_levels.*) {
            var i = num_levels.*;
            while (i > insert_pos) : (i -= 1) {
                levels[i] = levels[i - 1];
            }
        }

        // Initialize new level
        levels[insert_pos] = PriceLevel.init();
        levels[insert_pos].price = price;
        levels[insert_pos].active = true;

        num_levels.* += 1;

        return insert_pos;
    }

    fn removePriceLevel(
        self: *Self,
        levels: *[MAX_PRICE_LEVELS]PriceLevel,
        num_levels: *u32,
        index: u32,
    ) void {
        if (index >= num_levels.*) return;

        // Free all orders at this level
        self.listFreeAll(levels[index].orders_head);

        // Shift elements down
        if (index < num_levels.* - 1) {
            var i = index;
            while (i < num_levels.* - 1) : (i += 1) {
                levels[i] = levels[i + 1];
            }
        }

        num_levels.* -= 1;
    }

    // ========================================================================
    // Linked List Operations
    // ========================================================================

    fn listAppend(self: *Self, head: *?*Order, tail: *?*Order, order: *Order) void {
        _ = self;
        order.next = null;
        order.prev = tail.*;

        if (tail.*) |old_tail| {
            old_tail.next = order;
        }
        tail.* = order;

        if (head.* == null) {
            head.* = order;
        }
    }

    fn listRemove(self: *Self, head: *?*Order, tail: *?*Order, order: *Order) void {
        _ = self;
        const prev_order = order.prev;
        const next_order = order.next;

        if (prev_order) |prev| {
            prev.next = next_order;
        } else {
            head.* = next_order;
        }

        if (next_order) |next| {
            next.prev = prev_order;
        } else {
            tail.* = prev_order;
        }

        order.next = null;
        order.prev = null;
    }

    fn listFreeAll(self: *Self, head: ?*Order) void {
        var current = head;
        var count: u32 = 0;

        while (current != null and count < MAX_ORDERS_IN_POOL) : (count += 1) {
            const next = current.?.next;
            self.pool.free(current.?);
            current = next;
        }

        std.debug.assert(count < MAX_ORDERS_IN_POOL); // Rule 5
    }

    // ========================================================================
    // Flush Implementation
    // ========================================================================

    fn flushProcessSide(
        self: *Self,
        levels: *[MAX_PRICE_LEVELS]PriceLevel,
        num_levels: u32,
        current_level: *u32,
        current_order: *?*Order,
        side_done: *bool,
        budget: u32,
        output: *OutputBuffer,
    ) u32 {
        var processed: u32 = 0;

        while (!side_done.* and processed < budget) {
            if (current_level.* >= num_levels) {
                side_done.* = true;
                break;
            }

            const level = &levels[current_level.*];

            if (current_order.* == null) {
                current_order.* = level.orders_head;
            }

            while (current_order.* != null and processed < budget) {
                const order = current_order.*.?;
                current_order.* = order.next;

                output.addCancelAck(
                    msg.symbolSlice(&self.symbol),
                    order.user_id,
                    order.user_order_id,
                );
                processed += 1;
            }

            if (current_order.* == null) {
                current_level.* += 1;
            }
        }

        return processed;
    }

    fn flushFinalize(self: *Self, output: *OutputBuffer) void {
        const symbol = msg.symbolSlice(&self.symbol);

        // Free all bid levels
        for (self.bids[0..self.num_bid_levels]) |*level| {
            self.listFreeAll(level.orders_head);
            level.reset();
        }
        self.num_bid_levels = 0;

        // Free all ask levels
        for (self.asks[0..self.num_ask_levels]) |*level| {
            self.listFreeAll(level.orders_head);
            level.reset();
        }
        self.num_ask_levels = 0;

        // Clear order map
        self.order_map.clear();

        // Emit TOB eliminated messages
        if (self.bid_side_ever_active) {
            output.addTopOfBookEliminated(symbol, .buy);
        }
        if (self.ask_side_ever_active) {
            output.addTopOfBookEliminated(symbol, .sell);
        }

        // Reset tracking state
        self.prev_best_bid_price = 0;
        self.prev_best_bid_qty = 0;
        self.prev_best_ask_price = 0;
        self.prev_best_ask_qty = 0;
        self.bid_side_ever_active = false;
        self.ask_side_ever_active = false;

        // Reset flush state
        self.flush_state.reset();
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Create order key from user_id and user_order_id
pub fn makeOrderKey(user_id: u32, user_order_id: u32) u64 {
    std.debug.assert(user_id != 0 or user_order_id != 0); // Rule 5

    const key = (@as(u64, user_id) << 32) | user_order_id;

    std.debug.assert(key != HASH_SLOT_TOMBSTONE); // Rule 5

    return key;
}

/// Hash function for order key (multiply-shift)
pub fn hashOrderKey(key: u64) u32 {
    std.debug.assert(key != HASH_SLOT_EMPTY); // Rule 5
    std.debug.assert(key != HASH_SLOT_TOMBSTONE); // Rule 5

    const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;

    var k = key;
    k ^= k >> 33;
    k *%= GOLDEN_RATIO;
    k ^= k >> 29;

    return @truncate(k & ORDER_MAP_MASK);
}

// ============================================================================
// Tests
// ============================================================================

test "order book init" {
    const book = OrderBook.init("IBM");
    try std.testing.expectEqualStrings("IBM", msg.symbolSlice(&book.symbol));
    try std.testing.expectEqual(@as(u32, 0), book.num_bid_levels);
    try std.testing.expectEqual(@as(u32, 0), book.num_ask_levels);
}

test "order book add and match orders" {
    var book = OrderBook.init("IBM");
    var output = OutputBuffer.init();

    // Add a sell order at 100
    var sell_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 100,
        .quantity = 500,
        .side = .sell,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&sell_order.symbol, "IBM");

    book.addOrder(&sell_order, 0, &output);

    // Should have 1 ack
    try std.testing.expectEqual(@as(u32, 1), output.len());
    try std.testing.expectEqual(msg.OutputMsgType.ack, output.get(0).type);

    // Should have 1 ask level
    try std.testing.expectEqual(@as(u32, 1), book.num_ask_levels);
    try std.testing.expectEqual(@as(u32, 100), book.getBestAskPrice());

    output.reset();

    // Add a buy order that matches
    var buy_order = msg.NewOrderMsg{
        .user_id = 2,
        .user_order_id = 1,
        .price = 100,
        .quantity = 300,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&buy_order.symbol, "IBM");

    book.addOrder(&buy_order, 0, &output);

    // Should have 1 ack + 1 trade
    try std.testing.expectEqual(@as(u32, 2), output.len());

    // First message should be ack
    try std.testing.expectEqual(msg.OutputMsgType.ack, output.get(0).type);

    // Second message should be trade
    try std.testing.expectEqual(msg.OutputMsgType.trade, output.get(1).type);
    try std.testing.expectEqual(@as(u32, 300), output.get(1).data.trade.quantity);
    try std.testing.expectEqual(@as(u32, 100), output.get(1).data.trade.price);

    // Sell order should have 200 remaining
    try std.testing.expectEqual(@as(u32, 1), book.num_ask_levels);
    try std.testing.expectEqual(@as(u32, 200), book.getBestAskQuantity());
}

test "order book cancel" {
    var book = OrderBook.init("AAPL");
    var output = OutputBuffer.init();

    // Add an order
    var order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 150,
        .quantity = 1000,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&order.symbol, "AAPL");

    book.addOrder(&order, 0, &output);
    try std.testing.expectEqual(@as(u32, 1), book.num_bid_levels);

    output.reset();

    // Cancel the order
    book.cancelOrder(1, 100, &output);

    // Should have cancel ack
    try std.testing.expectEqual(@as(u32, 1), output.len());
    try std.testing.expectEqual(msg.OutputMsgType.cancel_ack, output.get(0).type);

    // Book should be empty
    try std.testing.expectEqual(@as(u32, 0), book.num_bid_levels);
}

test "make order key" {
    const key = makeOrderKey(1, 100);
    try std.testing.expectEqual(@as(u64, (1 << 32) | 100), key);
}

test "hash order key distribution" {
    // Test that hash produces reasonable distribution
    var buckets: [16]u32 = [_]u32{0} ** 16;

    for (1..1000) |i| {
        const key = makeOrderKey(@intCast(i), @intCast(i * 7));
        const hash = hashOrderKey(key);
        buckets[hash & 0xF] += 1;
    }

    // Check no bucket is severely over/under-represented
    for (buckets) |count| {
        try std.testing.expect(count > 20); // Should have at least some hits
        try std.testing.expect(count < 150); // Shouldn't be too concentrated
    }
}
