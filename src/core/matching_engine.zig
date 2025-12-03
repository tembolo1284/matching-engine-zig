//! Multi-symbol matching engine orchestrator.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const OrderBook = @import("order_book.zig").OrderBook;
const OutputBuffer = @import("order_book.zig").OutputBuffer;
const MemoryPools = @import("memory_pool.zig").MemoryPools;
const config = @import("../transport/config.zig");

pub const SYMBOL_MAP_SIZE = 512;
pub const SYMBOL_MAP_MASK = SYMBOL_MAP_SIZE - 1;
pub const ORDER_SYMBOL_MAP_SIZE = 16384;
pub const ORDER_SYMBOL_MAP_MASK = ORDER_SYMBOL_MAP_SIZE - 1;
pub const MAX_PROBE_LENGTH = 64;

comptime {
    std.debug.assert(SYMBOL_MAP_SIZE & (SYMBOL_MAP_SIZE - 1) == 0);
    std.debug.assert(ORDER_SYMBOL_MAP_SIZE & (ORDER_SYMBOL_MAP_SIZE - 1) == 0);
}

const SymbolSlot = struct {
    symbol: msg.Symbol,
    book_index: u16,
    active: bool,
};

const OrderSymbolSlot = struct {
    key: u64,
    symbol: msg.Symbol,
    active: bool,
};

pub const MatchingEngine = struct {
    books: [SYMBOL_MAP_SIZE]?OrderBook = [_]?OrderBook{null} ** SYMBOL_MAP_SIZE,
    num_books: usize = 0,

    symbol_map: [SYMBOL_MAP_SIZE]SymbolSlot = undefined,
    order_symbol_map: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot = undefined,

    pools: *MemoryPools,

    total_orders: u64 = 0,
    total_cancels: u64 = 0,
    total_trades: u64 = 0,

    const Self = @This();

    pub fn init(pools: *MemoryPools) Self {
        var engine = Self{ .pools = pools };

        for (&engine.symbol_map) |*slot| {
            slot.active = false;
        }
        for (&engine.order_symbol_map) |*slot| {
            slot.active = false;
        }

        return engine;
    }

    pub fn processMessage(
        self: *Self,
        message: *const msg.InputMsg,
        client_id: config.ClientId,
        output: *OutputBuffer,
    ) void {
        switch (message.msg_type) {
            .new_order => self.handleNewOrder(&message.data.new_order, client_id, output),
            .cancel => self.handleCancel(&message.data.cancel, client_id, output),
            .flush => self.handleFlush(output),
        }
    }

    fn handleNewOrder(
        self: *Self,
        order: *const msg.NewOrderMsg,
        client_id: config.ClientId,
        output: *OutputBuffer,
    ) void {
        self.total_orders += 1;

        const book = self.findOrCreateBook(order.symbol) orelse {
            output.add(msg.OutputMsg.makeReject(
                order.user_id,
                order.user_order_id,
                .unknown_symbol,
                order.symbol,
                client_id,
            ));
            return;
        };

        // Track order → symbol mapping for cancel routing
        const key = makeOrderKey(order.user_id, order.user_order_id);
        self.trackOrderSymbol(key, order.symbol);

        book.addOrder(order, client_id, output);
    }

    fn handleCancel(
        self: *Self,
        cancel: *const msg.CancelMsg,
        client_id: config.ClientId,
        output: *OutputBuffer,
    ) void {
        self.total_cancels += 1;

        const key = makeOrderKey(cancel.user_id, cancel.user_order_id);

        // Look up symbol from order tracking
        const symbol = self.lookupOrderSymbol(key) orelse cancel.symbol;

        if (msg.symbolIsEmpty(&symbol)) {
            // Symbol unknown - try all books
            for (&self.books) |*maybe_book| {
                if (maybe_book.*) |*book| {
                    book.cancelOrder(cancel.user_id, cancel.user_order_id, client_id, output);
                }
            }
        } else {
            // Route to specific book
            if (self.findBook(symbol)) |book| {
                book.cancelOrder(cancel.user_id, cancel.user_order_id, client_id, output);
            } else {
                output.add(msg.OutputMsg.makeReject(
                    cancel.user_id,
                    cancel.user_order_id,
                    .order_not_found,
                    symbol,
                    client_id,
                ));
            }
        }

        // Remove from tracking
        self.removeOrderSymbol(key);
    }

    fn handleFlush(self: *Self, output: *OutputBuffer) void {
        for (&self.books) |*maybe_book| {
            if (maybe_book.*) |*book| {
                book.flush(output);
            }
        }

        // Clear order tracking
        for (&self.order_symbol_map) |*slot| {
            slot.active = false;
        }
    }

    /// Cancel all orders for a specific client (on disconnect)
    pub fn cancelClientOrders(self: *Self, client_id: config.ClientId, output: *OutputBuffer) usize {
        var cancelled: usize = 0;

        for (&self.books) |*maybe_book| {
            if (maybe_book.*) |*book| {
                cancelled += book.cancelClientOrders(client_id, output);
            }
        }

        return cancelled;
    }

    fn findOrCreateBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        // First try to find existing
        if (self.findBook(symbol)) |book| {
            return book;
        }

        // Create new book
        const idx = hashSymbol(symbol);
        var probe: usize = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;

            if (!self.symbol_map[slot_idx].active) {
                // Found empty slot
                if (self.books[slot_idx] == null) {
                    self.books[slot_idx] = OrderBook.init(symbol, self.pools);
                } else {
                    self.books[slot_idx].?.reset(symbol);
                }

                self.symbol_map[slot_idx] = .{
                    .symbol = symbol,
                    .book_index = @intCast(slot_idx),
                    .active = true,
                };
                self.num_books += 1;

                return &self.books[slot_idx].?;
            }
        }

        return null;
    }

    fn findBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        const idx = hashSymbol(symbol);
        var probe: usize = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;
            const slot = &self.symbol_map[slot_idx];

            if (!slot.active) return null;

            if (msg.symbolEqual(slot.symbol, symbol)) {
                return &self.books[slot.book_index].?;
            }
        }

        return null;
    }

    fn trackOrderSymbol(self: *Self, key: u64, symbol: msg.Symbol) void {
        const idx = hashOrderKey(key);
        var probe: usize = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;

            if (!self.order_symbol_map[slot_idx].active) {
                self.order_symbol_map[slot_idx] = .{
                    .key = key,
                    .symbol = symbol,
                    .active = true,
                };
                return;
            }
        }
    }

    fn lookupOrderSymbol(self: *Self, key: u64) ?msg.Symbol {
        const idx = hashOrderKey(key);
        var probe: usize = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.active) return null;
            if (slot.key == key) return slot.symbol;
        }

        return null;
    }

    fn removeOrderSymbol(self: *Self, key: u64) void {
        const idx = hashOrderKey(key);
        var probe: usize = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.active) return;
            if (slot.key == key) {
                slot.active = false;
                return;
            }
        }
    }

    fn hashSymbol(symbol: msg.Symbol) u32 {
        var hash: u32 = 2166136261;
        for (symbol) |byte| {
            if (byte == 0) break;
            hash ^= byte;
            hash *%= 16777619;
        }
        return hash & SYMBOL_MAP_MASK;
    }

    fn hashOrderKey(key: u64) u32 {
        const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;
        var k = key;
        k ^= k >> 33;
        k *%= GOLDEN_RATIO;
        k ^= k >> 29;
        return @intCast(k & ORDER_SYMBOL_MAP_MASK);
    }

    fn makeOrderKey(user_id: u32, order_id: u32) u64 {
        return (@as(u64, user_id) << 32) | order_id;
    }
};
