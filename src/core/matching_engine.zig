//! MatchingEngine - Multi-Symbol Order Book Orchestrator
//!
//! Design principles (Power of Ten + cache optimization):
//! - Open-addressing hash tables (no pointer chasing)
//! - Power-of-2 table sizes for fast masking
//! - Tombstone-based deletion
//! - No dynamic allocation after init (Rule 3)
//!
//! TCP multi-client support:
//! - Tracks client_id with each order for ownership
//! - Supports cancelling all orders for a disconnected client

const std = @import("std");
const OrderBook = @import("order_book.zig").OrderBook;
const makeOrderKey = @import("order_book.zig").makeOrderKey;
const OutputBuffer = @import("output_buffer.zig").OutputBuffer;
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Configuration Constants
// ============================================================================

pub const MAX_SYMBOLS: u32 = 64;

/// Symbol map size - power of 2 for fast masking
pub const SYMBOL_MAP_SIZE: u32 = 512;
const SYMBOL_MAP_MASK: u32 = SYMBOL_MAP_SIZE - 1;

/// Order-symbol map size - power of 2 for fast masking
pub const ORDER_SYMBOL_MAP_SIZE: u32 = 8192;
const ORDER_SYMBOL_MAP_MASK: u32 = ORDER_SYMBOL_MAP_SIZE - 1;

/// Maximum probe lengths (Rule 2)
pub const MAX_SYMBOL_PROBE_LENGTH: u32 = 64;
pub const MAX_ORDER_SYMBOL_PROBE_LENGTH: u32 = 128;

/// Sentinel values
pub const ORDER_KEY_EMPTY: u64 = 0;
pub const ORDER_KEY_TOMBSTONE: u64 = std.math.maxInt(u64);

// Compile-time verification
comptime {
    std.debug.assert((SYMBOL_MAP_SIZE & (SYMBOL_MAP_SIZE - 1)) == 0);
    std.debug.assert((ORDER_SYMBOL_MAP_SIZE & (ORDER_SYMBOL_MAP_SIZE - 1)) == 0);
}

// ============================================================================
// Symbol Map - Open-Addressing Hash Table
// ============================================================================

const SymbolMapSlot = struct {
    symbol: msg.Symbol,
    book_index: i32,

    pub fn isEmpty(self: *const SymbolMapSlot) bool {
        return self.symbol[0] == 0;
    }
};

const SymbolMap = struct {
    slots: [SYMBOL_MAP_SIZE]SymbolMapSlot,
    count: u32,

    const Self = @This();

    pub fn init() Self {
        var self = Self{
            .slots = undefined,
            .count = 0,
        };
        for (&self.slots) |*slot| {
            @memset(&slot.symbol, 0);
            slot.book_index = -1;
        }
        return self;
    }

    pub fn initInPlace(self: *Self) void {
        self.count = 0;
        for (&self.slots) |*slot| {
            @memset(&slot.symbol, 0);
            slot.book_index = -1;
        }
    }

    pub fn find(self: *Self, symbol: []const u8) ?*SymbolMapSlot {
        std.debug.assert(symbol.len > 0);

        const hash = hashSymbol(symbol);

        var i: u32 = 0;
        while (i < MAX_SYMBOL_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & SYMBOL_MAP_MASK;
            const slot = &self.slots[idx];

            if (symbolEqual(&slot.symbol, symbol)) {
                return slot;
            }

            if (slot.isEmpty()) {
                return null;
            }
        }

        return null;
    }

    pub fn insert(self: *Self, symbol: []const u8, book_index: i32) ?*SymbolMapSlot {
        std.debug.assert(symbol.len > 0);
        std.debug.assert(symbol[0] != 0);

        const hash = hashSymbol(symbol);

        var i: u32 = 0;
        while (i < MAX_SYMBOL_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & SYMBOL_MAP_MASK;
            const slot = &self.slots[idx];

            if (slot.isEmpty()) {
                msg.copySymbol(&slot.symbol, symbol);
                slot.book_index = book_index;
                self.count += 1;
                return slot;
            }

            if (symbolEqual(&slot.symbol, symbol)) {
                slot.book_index = book_index;
                return slot;
            }
        }

        return null;
    }
};

// ============================================================================
// Order-Symbol Map - For Cancel Lookups
// ============================================================================

const OrderSymbolSlot = struct {
    order_key: u64,
    symbol: msg.Symbol,
};

const OrderSymbolMap = struct {
    slots: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot,
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
            slot.order_key = ORDER_KEY_EMPTY;
            @memset(&slot.symbol, 0);
        }
        return self;
    }

    pub fn initInPlace(self: *Self) void {
        self.count = 0;
        self.tombstone_count = 0;
        for (&self.slots) |*slot| {
            slot.order_key = ORDER_KEY_EMPTY;
            @memset(&slot.symbol, 0);
        }
    }

    pub fn insert(self: *Self, order_key: u64, symbol: []const u8) bool {
        std.debug.assert(order_key != ORDER_KEY_EMPTY);
        std.debug.assert(order_key != ORDER_KEY_TOMBSTONE);
        std.debug.assert(symbol.len > 0);

        const hash = hashOrderKey(order_key);

        var i: u32 = 0;
        while (i < MAX_ORDER_SYMBOL_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.slots[idx];

            if (slot.order_key == ORDER_KEY_EMPTY or slot.order_key == ORDER_KEY_TOMBSTONE) {
                if (slot.order_key == ORDER_KEY_TOMBSTONE) {
                    self.tombstone_count -= 1;
                }
                slot.order_key = order_key;
                msg.copySymbol(&slot.symbol, symbol);
                self.count += 1;
                return true;
            }

            if (slot.order_key == order_key) {
                msg.copySymbol(&slot.symbol, symbol);
                return true;
            }
        }

        return false;
    }

    pub fn find(self: *Self, order_key: u64) ?*OrderSymbolSlot {
        if (order_key == ORDER_KEY_EMPTY or order_key == ORDER_KEY_TOMBSTONE) {
            return null;
        }

        const hash = hashOrderKey(order_key);

        var i: u32 = 0;
        while (i < MAX_ORDER_SYMBOL_PROBE_LENGTH) : (i += 1) {
            const idx = (hash + i) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.slots[idx];

            if (slot.order_key == order_key) {
                return slot;
            }

            if (slot.order_key == ORDER_KEY_EMPTY) {
                return null;
            }
        }

        return null;
    }

    pub fn remove(self: *Self, order_key: u64) bool {
        if (self.find(order_key)) |slot| {
            slot.order_key = ORDER_KEY_TOMBSTONE;
            self.count -= 1;
            self.tombstone_count += 1;
            return true;
        }
        return false;
    }

    pub fn clear(self: *Self) void {
        for (&self.slots) |*slot| {
            slot.order_key = ORDER_KEY_EMPTY;
        }
        self.count = 0;
        self.tombstone_count = 0;
        std.debug.assert(self.count == 0);
    }
};

// ============================================================================
// Matching Engine Structure
// ============================================================================

pub const MatchingEngine = struct {
    symbol_map: SymbolMap,
    order_to_symbol: OrderSymbolMap,
    books: [MAX_SYMBOLS]OrderBook,
    num_books: u32,
    flush_in_progress: bool,
    flush_book_index: u32,

    const Self = @This();

    /// Initialize matching engine (WARNING: creates large struct on stack)
    pub fn init() Self {
        var self: Self = undefined;
        self.initInPlace();
        return self;
    }

    /// Initialize matching engine in-place (avoids stack allocation)
    pub fn initInPlace(self: *Self) void {
        self.symbol_map.initInPlace();
        self.order_to_symbol.initInPlace();
        self.num_books = 0;
        self.flush_in_progress = false;
        self.flush_book_index = 0;

        for (&self.books) |*book| {
            book.* = OrderBook.init("_UNINIT_");
        }

        std.debug.assert(self.num_books == 0);
    }

    pub fn processMessage(
        self: *Self,
        input: *const msg.InputMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(msg.InputMsgType.isValid(@intFromEnum(input.type)));

        switch (input.type) {
            .new_order => self.processNewOrder(&input.data.new_order, client_id, output),
            .cancel => self.processCancelOrder(&input.data.cancel, output),
            .flush => self.processFlush(output),
        }
    }

    pub fn processNewOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(order_msg.quantity > 0);

        const symbol = msg.symbolSlice(&order_msg.symbol);

        const book = self.getOrCreateOrderBook(symbol) orelse {
            output.addAck(symbol, order_msg.user_id, order_msg.user_order_id);
            return;
        };

        const order_key = makeOrderKey(order_msg.user_id, order_msg.user_order_id);
        _ = self.order_to_symbol.insert(order_key, symbol);

        book.addOrder(order_msg, client_id, output);
    }

    pub fn processCancelOrder(
        self: *Self,
        cancel_msg: *const msg.CancelMsg,
        output: *OutputBuffer,
    ) void {
        const order_key = makeOrderKey(cancel_msg.user_id, cancel_msg.user_order_id);

        const entry = self.order_to_symbol.find(order_key);
        if (entry == null) {
            output.addCancelAck("UNKNOWN", cancel_msg.user_id, cancel_msg.user_order_id);
            return;
        }

        const symbol = msg.symbolSlice(&entry.?.symbol);

        const book_slot = self.symbol_map.find(symbol);
        if (book_slot == null) {
            output.addCancelAck(symbol, cancel_msg.user_id, cancel_msg.user_order_id);
            _ = self.order_to_symbol.remove(order_key);
            return;
        }

        std.debug.assert(book_slot.?.book_index >= 0);
        const book_index: u32 = @intCast(book_slot.?.book_index);
        std.debug.assert(book_index < self.num_books);

        self.books[book_index].cancelOrder(
            cancel_msg.user_id,
            cancel_msg.user_order_id,
            output,
        );

        _ = self.order_to_symbol.remove(order_key);
    }

    pub fn processFlush(self: *Self, output: *OutputBuffer) void {
        self.flush_in_progress = true;
        self.flush_book_index = 0;

        for (self.books[0..self.num_books]) |*book| {
            _ = book.flush(output);
        }

        self.order_to_symbol.clear();

        // Check if all books completed flush
        var all_done = true;
        for (self.books[0..self.num_books]) |*book| {
            if (book.flushInProgress()) {
                all_done = false;
                break;
            }
        }

        if (all_done) {
            self.flush_in_progress = false;
        }
    }

    pub fn continueFlush(self: *Self, output: *OutputBuffer) bool {
        if (!self.flush_in_progress) return true;

        var all_done = true;
        for (self.books[0..self.num_books]) |*book| {
            if (book.flushInProgress()) {
                const done = book.flush(output);
                if (!done) {
                    all_done = false;
                }
            }
        }

        if (all_done) {
            self.flush_in_progress = false;
        }

        return all_done;
    }

    pub fn hasFlushInProgress(self: *Self) bool {
        return self.flush_in_progress;
    }

    pub fn cancelClientOrders(
        self: *Self,
        client_id: u32,
        output: *OutputBuffer,
    ) usize {
        var total_cancelled: usize = 0;
        for (self.books[0..self.num_books]) |*book| {
            total_cancelled += book.cancelClientOrders(client_id, output);
        }
        return total_cancelled;
    }

    pub fn getOrCreateOrderBook(self: *Self, symbol: []const u8) ?*OrderBook {
        std.debug.assert(symbol.len > 0);

        if (self.symbol_map.find(symbol)) |slot| {
            std.debug.assert(slot.book_index >= 0);
            const idx: u32 = @intCast(slot.book_index);
            std.debug.assert(idx < self.num_books);
            return &self.books[idx];
        }

        if (self.num_books >= MAX_SYMBOLS) {
            return null;
        }

        const book_index = self.num_books;
        self.books[book_index] = OrderBook.init(symbol);
        self.num_books += 1;

        const new_slot = self.symbol_map.insert(symbol, @intCast(book_index));
        if (new_slot == null) {
            self.num_books -= 1;
            return null;
        }

        return &self.books[book_index];
    }

    pub fn getOrderBook(self: *Self, symbol: []const u8) ?*OrderBook {
        if (self.symbol_map.find(symbol)) |slot| {
            if (slot.book_index >= 0) {
                const idx: u32 = @intCast(slot.book_index);
                if (idx < self.num_books) {
                    return &self.books[idx];
                }
            }
        }
        return null;
    }

    pub fn generateTopOfBook(self: *Self, symbol: []const u8, output: *OutputBuffer) void {
        if (self.getOrderBook(symbol)) |book| {
            book.generateTopOfBook(output);
        }
    }

    pub fn generateAllTopOfBook(self: *Self, output: *OutputBuffer) void {
        for (self.books[0..self.num_books]) |*book| {
            book.generateTopOfBook(output);
        }
    }

    pub fn getNumBooks(self: *const Self) u32 {
        return self.num_books;
    }

    pub const Stats = struct {
        num_books: u32,
        symbol_map_count: u32,
        order_symbol_map_count: u32,
        order_symbol_tombstones: u32,
    };

    pub fn getStats(self: *const Self) Stats {
        return Stats{
            .num_books = self.num_books,
            .symbol_map_count = self.symbol_map.count,
            .order_symbol_map_count = self.order_to_symbol.count,
            .order_symbol_tombstones = self.order_to_symbol.tombstone_count,
        };
    }
};

// ============================================================================
// Hash Functions
// ============================================================================

fn hashSymbol(symbol: []const u8) u32 {
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
    return @truncate(k & ORDER_SYMBOL_MAP_MASK);
}

fn symbolEqual(symbol: *const msg.Symbol, other: []const u8) bool {
    const sym_slice = msg.symbolSlice(symbol);
    return std.mem.eql(u8, sym_slice, other);
}

// ============================================================================
// Tests
// ============================================================================

test "matching engine init" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();
    try std.testing.expectEqual(@as(u32, 0), engine.num_books);
    try std.testing.expectEqual(@as(u32, 0), engine.symbol_map.count);
}

test "matching engine create order book" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();

    const book = engine.getOrCreateOrderBook("IBM");
    try std.testing.expect(book != null);
    try std.testing.expectEqual(@as(u32, 1), engine.num_books);

    const book2 = engine.getOrCreateOrderBook("IBM");
    try std.testing.expect(book2 != null);
    try std.testing.expectEqual(@as(u32, 1), engine.num_books);
    try std.testing.expectEqual(book, book2);

    const book3 = engine.getOrCreateOrderBook("AAPL");
    try std.testing.expect(book3 != null);
    try std.testing.expectEqual(@as(u32, 2), engine.num_books);
    try std.testing.expect(book != book3);
}

test "matching engine process new order" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();
    var output = OutputBuffer.init();

    var order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 150,
        .quantity = 1000,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&order.symbol, "IBM");

    engine.processNewOrder(&order, 0, &output);

    try std.testing.expectEqual(@as(u32, 1), output.len());
    try std.testing.expectEqual(msg.OutputMsgType.ack, output.get(0).type);
    try std.testing.expectEqual(@as(u32, 1), engine.num_books);
    try std.testing.expectEqual(@as(u32, 1), engine.order_to_symbol.count);
}

test "matching engine cancel order" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();
    var output = OutputBuffer.init();

    var order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 150,
        .quantity = 1000,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&order.symbol, "IBM");
    engine.processNewOrder(&order, 0, &output);
    output.reset();

    var cancel = msg.CancelMsg{
        .user_id = 1,
        .user_order_id = 100,
        .symbol = undefined,
    };
    msg.copySymbol(&cancel.symbol, "IBM");
    engine.processCancelOrder(&cancel, &output);

    try std.testing.expectEqual(@as(u32, 1), output.len());
    try std.testing.expectEqual(msg.OutputMsgType.cancel_ack, output.get(0).type);
    try std.testing.expectEqual(@as(u32, 0), engine.order_to_symbol.count);
}

test "matching engine flush" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();
    var output = OutputBuffer.init();

    var order1 = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 100,
        .quantity = 500,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&order1.symbol, "IBM");

    var order2 = msg.NewOrderMsg{
        .user_id = 2,
        .user_order_id = 1,
        .price = 200,
        .quantity = 300,
        .side = .sell,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&order2.symbol, "AAPL");

    engine.processNewOrder(&order1, 0, &output);
    engine.processNewOrder(&order2, 0, &output);
    output.reset();

    engine.processFlush(&output);

    try std.testing.expect(output.len() >= 2);
    try std.testing.expectEqual(@as(u32, 0), engine.order_to_symbol.count);
}

test "matching engine trade" {
    var engine: MatchingEngine = undefined;
    engine.initInPlace();
    var output = OutputBuffer.init();

    var sell = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 100,
        .quantity = 500,
        .side = .sell,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&sell.symbol, "IBM");
    engine.processNewOrder(&sell, 10, &output);
    output.reset();

    var buy = msg.NewOrderMsg{
        .user_id = 2,
        .user_order_id = 1,
        .price = 100,
        .quantity = 300,
        .side = .buy,
        ._pad = .{ 0, 0, 0 },
        .symbol = undefined,
    };
    msg.copySymbol(&buy.symbol, "IBM");
    engine.processNewOrder(&buy, 20, &output);

    try std.testing.expectEqual(@as(u32, 2), output.len());
    try std.testing.expectEqual(msg.OutputMsgType.ack, output.get(0).type);
    try std.testing.expectEqual(msg.OutputMsgType.trade, output.get(1).type);

    const trade = &output.get(1).data.trade;
    try std.testing.expectEqual(@as(u32, 2), trade.user_id_buy);
    try std.testing.expectEqual(@as(u32, 1), trade.user_id_sell);
    try std.testing.expectEqual(@as(u32, 300), trade.quantity);
    try std.testing.expectEqual(@as(u32, 100), trade.price);
}

test "hash symbol distribution" {
    var buckets: [16]u32 = [_]u32{0} ** 16;

    const symbols = [_][]const u8{
        "IBM",  "AAPL", "GOOG", "MSFT", "AMZN", "META", "NVDA", "TSLA",
        "JPM",  "BAC",  "WFC",  "C",    "GS",   "MS",   "BRK",  "UNH",
        "JNJ",  "PFE",  "MRK",  "ABBV", "LLY",  "TMO",  "ABT",  "DHR",
        "XOM",  "CVX",  "COP",  "EOG",  "SLB",  "PXD",  "VLO",  "MPC",
    };

    for (symbols) |sym| {
        const hash = hashSymbol(sym);
        buckets[hash & 0xF] += 1;
    }

    for (buckets) |count| {
        try std.testing.expect(count <= 8);
    }
}
