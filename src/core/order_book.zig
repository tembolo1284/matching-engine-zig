//! Single-symbol order book with price-time priority.
//! Updated to pass symbol to all output messages.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const Order = @import("order.zig").Order;
const getCurrentTimestamp = @import("order.zig").getCurrentTimestamp;
const MemoryPools = @import("memory_pool.zig").MemoryPools;

// ... (keep all the constants and other types the same as before)

pub const MAX_PRICE_LEVELS = 10000;
pub const MAX_OUTPUT_MESSAGES = 8192;
pub const ORDER_MAP_SIZE = 262144;
pub const ORDER_MAP_MASK = ORDER_MAP_SIZE - 1;
pub const MAX_PROBE_LENGTH = 128;
pub const MAX_MATCH_ITERATIONS = 200000;

comptime {
    std.debug.assert(ORDER_MAP_SIZE & (ORDER_MAP_SIZE - 1) == 0);
}

const HASH_SLOT_EMPTY: u64 = 0;
const HASH_SLOT_TOMBSTONE: u64 = std.math.maxInt(u64);

pub const OrderLocation = struct {
    side: msg.Side,
    price: u32,
    order_ptr: *Order,
};

const OrderMapSlot = struct {
    key: u64,
    location: OrderLocation,
};

pub const OrderMap = struct {
    slots: [ORDER_MAP_SIZE]OrderMapSlot = undefined,
    count: u32 = 0,
    tombstone_count: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }
        return self;
    }

    pub inline fn makeKey(user_id: u32, user_order_id: u32) u64 {
        return (@as(u64, user_id) << 32) | user_order_id;
    }

    inline fn hash(key: u64) u32 {
        const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;
        var k = key;
        k ^= k >> 33;
        k *%= GOLDEN_RATIO;
        k ^= k >> 29;
        return @intCast(k & ORDER_MAP_MASK);
    }

    pub fn insert(self: *Self, key: u64, location: OrderLocation) bool {
        var idx = hash(key);

        for (0..MAX_PROBE_LENGTH) |_| {
            const slot_key = self.slots[idx].key;

            if (slot_key == HASH_SLOT_EMPTY or slot_key == HASH_SLOT_TOMBSTONE) {
                self.slots[idx] = .{ .key = key, .location = location };
                self.count += 1;
                if (slot_key == HASH_SLOT_TOMBSTONE) {
                    self.tombstone_count -= 1;
                }
                return true;
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }
        return false;
    }

    pub fn find(self: *const Self, key: u64) ?*const OrderLocation {
        var idx = hash(key);

        for (0..MAX_PROBE_LENGTH) |_| {
            const slot = &self.slots[idx];

            if (slot.key == HASH_SLOT_EMPTY) return null;
            if (slot.key == key) return &slot.location;

            idx = (idx + 1) & ORDER_MAP_MASK;
        }
        return null;
    }

    pub fn remove(self: *Self, key: u64) bool {
        var idx = hash(key);

        for (0..MAX_PROBE_LENGTH) |_| {
            if (self.slots[idx].key == HASH_SLOT_EMPTY) return false;
            if (self.slots[idx].key == key) {
                self.slots[idx].key = HASH_SLOT_TOMBSTONE;
                self.count -= 1;
                self.tombstone_count += 1;
                return true;
            }
            idx = (idx + 1) & ORDER_MAP_MASK;
        }
        return false;
    }
};

pub const PriceLevel = extern struct {
    price: u32,
    total_quantity: u32,
    orders_head: ?*Order,
    orders_tail: ?*Order,
    active: bool,
    _padding: [39]u8 = undefined,

    comptime {
        std.debug.assert(@sizeOf(@This()) == 64);
    }

    pub fn init(price: u32) PriceLevel {
        return .{
            .price = price,
            .total_quantity = 0,
            .orders_head = null,
            .orders_tail = null,
            .active = false,
        };
    }

    pub fn addOrder(self: *PriceLevel, order: *Order) void {
        order.next = null;
        order.prev = self.orders_tail;

        if (self.orders_tail) |tail| {
            tail.next = order;
        } else {
            self.orders_head = order;
        }
        self.orders_tail = order;
        self.total_quantity += order.remaining_qty;
        self.active = true;
    }

    pub fn removeOrder(self: *PriceLevel, order: *Order) void {
        self.total_quantity -|= order.remaining_qty;

        if (order.prev) |prev| {
            prev.next = order.next;
        } else {
            self.orders_head = order.next;
        }

        if (order.next) |next| {
            next.prev = order.prev;
        } else {
            self.orders_tail = order.prev;
        }

        order.next = null;
        order.prev = null;

        if (self.orders_head == null) {
            self.active = false;
            self.total_quantity = 0;
        }
    }
};

pub const OutputBuffer = struct {
    messages: [MAX_OUTPUT_MESSAGES]msg.OutputMsg = undefined,
    count: usize = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn hasSpace(self: *const Self, needed: usize) bool {
        return (self.count + needed) <= MAX_OUTPUT_MESSAGES;
    }

    pub fn add(self: *Self, message: msg.OutputMsg) void {
        if (self.count < MAX_OUTPUT_MESSAGES) {
            self.messages[self.count] = message;
            self.count += 1;
        }
    }

    pub fn clear(self: *Self) void {
        self.count = 0;
    }

    pub fn slice(self: *const Self) []const msg.OutputMsg {
        return self.messages[0..self.count];
    }
};

pub const OrderBook = struct {
    symbol: msg.Symbol,

    bids: [MAX_PRICE_LEVELS]PriceLevel = undefined,
    asks: [MAX_PRICE_LEVELS]PriceLevel = undefined,
    num_bid_levels: usize = 0,
    num_ask_levels: usize = 0,

    order_map: OrderMap,

    prev_best_bid_price: u32 = 0,
    prev_best_bid_qty: u32 = 0,
    prev_best_ask_price: u32 = 0,
    prev_best_ask_qty: u32 = 0,

    pools: *MemoryPools,

    const Self = @This();

    pub fn init(symbol: msg.Symbol, pools: *MemoryPools) Self {
        var book = Self{
            .symbol = symbol,
            .order_map = OrderMap.init(),
            .pools = pools,
        };

        for (&book.bids) |*level| {
            level.* = PriceLevel.init(0);
        }
        for (&book.asks) |*level| {
            level.* = PriceLevel.init(0);
        }

        return book;
    }

    pub fn addOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        if (order_msg.quantity == 0) {
            output.add(msg.OutputMsg.makeReject(
                order_msg.user_id,
                order_msg.user_order_id,
                .invalid_quantity,
                self.symbol, // Include symbol!
                client_id,
            ));
            return;
        }

        const order = self.pools.order_pool.acquire() orelse {
            output.add(msg.OutputMsg.makeReject(
                order_msg.user_id,
                order_msg.user_order_id,
                .pool_exhausted,
                self.symbol,
                client_id,
            ));
            return;
        };

        order.* = Order.init(order_msg, getCurrentTimestamp());
        order.client_id = client_id;

        // Ack with symbol
        output.add(msg.OutputMsg.makeAck(
            order.user_id,
            order.user_order_id,
            self.symbol,
            client_id,
        ));

        self.matchOrder(order, client_id, output);

        if (!order.isFilled()) {
            self.insertOrder(order);
            self.checkTopOfBookChange(output);
        } else {
            self.pools.order_pool.release(order);
        }
    }

    pub fn cancelOrder(
        self: *Self,
        user_id: u32,
        user_order_id: u32,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        const key = OrderMap.makeKey(user_id, user_order_id);

        if (self.order_map.find(key)) |loc| {
            const order = loc.order_ptr;

            const level = self.findLevel(loc.side, loc.price);
            if (level) |lvl| {
                lvl.removeOrder(order);
                self.cleanupEmptyLevels(loc.side);
            }

            _ = self.order_map.remove(key);
            self.pools.order_pool.release(order);

            // Cancel ack with symbol
            output.add(msg.OutputMsg.makeCancelAck(user_id, user_order_id, self.symbol, client_id));

            self.checkTopOfBookChange(output);
        } else {
            output.add(msg.OutputMsg.makeReject(
                user_id,
                user_order_id,
                .order_not_found,
                self.symbol,
                client_id,
            ));
        }
    }

    fn matchOrder(self: *Self, incoming: *Order, client_id: u32, output: *OutputBuffer) void {
        const opposite_side = incoming.side.opposite();
        var iterations: usize = 0;

        while (!incoming.isFilled() and iterations < MAX_MATCH_ITERATIONS) : (iterations += 1) {
            const best_level = self.getBestLevel(opposite_side) orelse break;

            if (!incoming.pricesCross(best_level.price) and incoming.price != 0) {
                break;
            }

            var resting = best_level.orders_head;
            while (resting) |rest_order| : (iterations += 1) {
                if (incoming.isFilled() or iterations >= MAX_MATCH_ITERATIONS) break;

                const next = rest_order.next;
                const fill_qty = @min(incoming.remaining_qty, rest_order.remaining_qty);
                const fill_price = rest_order.price;

                _ = incoming.fill(fill_qty);
                _ = rest_order.fill(fill_qty);

                // Determine buyer/seller
                const buyer_uid = if (incoming.side == .buy) incoming.user_id else rest_order.user_id;
                const buyer_oid = if (incoming.side == .buy) incoming.user_order_id else rest_order.user_order_id;
                const seller_uid = if (incoming.side == .sell) incoming.user_id else rest_order.user_id;
                const seller_oid = if (incoming.side == .sell) incoming.user_order_id else rest_order.user_order_id;

                // Trade to buyer with symbol
                output.add(msg.OutputMsg.makeTrade(
                    buyer_uid,
                    buyer_oid,
                    seller_uid,
                    seller_oid,
                    fill_price,
                    fill_qty,
                    self.symbol,
                    if (incoming.side == .buy) client_id else rest_order.client_id,
                ));

                // Trade to seller with symbol
                output.add(msg.OutputMsg.makeTrade(
                    buyer_uid,
                    buyer_oid,
                    seller_uid,
                    seller_oid,
                    fill_price,
                    fill_qty,
                    self.symbol,
                    if (incoming.side == .sell) client_id else rest_order.client_id,
                ));

                if (rest_order.isFilled()) {
                    best_level.removeOrder(rest_order);
                    const key = OrderMap.makeKey(rest_order.user_id, rest_order.user_order_id);
                    _ = self.order_map.remove(key);
                    self.pools.order_pool.release(rest_order);
                } else {
                    best_level.total_quantity -|= fill_qty;
                }

                resting = next;
            }

            if (!best_level.active or best_level.orders_head == null) {
                self.cleanupEmptyLevels(opposite_side);
            }
        }
    }

    fn insertOrder(self: *Self, order: *Order) void {
        const key = OrderMap.makeKey(order.user_id, order.user_order_id);
        const level = self.findOrCreateLevel(order.side, order.price);

        level.addOrder(order);

        _ = self.order_map.insert(key, .{
            .side = order.side,
            .price = order.price,
            .order_ptr = order,
        });
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

    fn findOrCreateLevel(self: *Self, side: msg.Side, price: u32) *PriceLevel {
        const levels = if (side == .buy) &self.bids else &self.asks;
        const count_ptr = if (side == .buy) &self.num_bid_levels else &self.num_ask_levels;

        var insert_idx: usize = count_ptr.*;

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
                insert_idx = i;
                break;
            }
        }

        if (count_ptr.* < MAX_PRICE_LEVELS) {
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

        return &levels[0];
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

        var write_idx: usize = 0;
        for (levels[0..count_ptr.*]) |level| {
            if (level.active and level.orders_head != null) {
                levels[write_idx] = level;
                write_idx += 1;
            }
        }
        count_ptr.* = write_idx;
    }

    fn checkTopOfBookChange(self: *Self, output: *OutputBuffer) void {
        // Best bid
        if (self.getBestLevel(.buy)) |bid| {
            if (bid.price != self.prev_best_bid_price or
                bid.total_quantity != self.prev_best_bid_qty)
            {
                output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .buy,
                    bid.price,
                    bid.total_quantity,
                ));
                self.prev_best_bid_price = bid.price;
                self.prev_best_bid_qty = bid.total_quantity;
            }
        } else if (self.prev_best_bid_price != 0) {
            output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .buy, 0, 0));
            self.prev_best_bid_price = 0;
            self.prev_best_bid_qty = 0;
        }

        // Best ask
        if (self.getBestLevel(.sell)) |ask| {
            if (ask.price != self.prev_best_ask_price or
                ask.total_quantity != self.prev_best_ask_qty)
            {
                output.add(msg.OutputMsg.makeTopOfBook(
                    self.symbol,
                    .sell,
                    ask.price,
                    ask.total_quantity,
                ));
                self.prev_best_ask_price = ask.price;
                self.prev_best_ask_qty = ask.total_quantity;
            }
        } else if (self.prev_best_ask_price != 0) {
            output.add(msg.OutputMsg.makeTopOfBook(self.symbol, .sell, 0, 0));
            self.prev_best_ask_price = 0;
            self.prev_best_ask_qty = 0;
        }
    }

    pub fn getBestBidPrice(self: *const Self) u32 {
        // Need non-const self for getBestLevel, use direct iteration
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
};
