//! Multi-symbol order book orchestrator.
//!
//! Routes orders to appropriate symbol books,
//! handles cancel lookups across books.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const OrderBook = @import("order_book.zig").OrderBook;
const OutputBuffer = @import("order_book.zig").OutputBuffer;
const MemoryPools = @import("memory_pool.zig").MemoryPools;

// ============================================================================
// Configuration
// ============================================================================

pub const MAX_SYMBOLS = 256;
pub const SYMBOL_MAP_SIZE = 512; // Power of 2
pub const SYMBOL_MAP_MASK = SYMBOL_MAP_SIZE - 1;
pub const MAX_SYMBOL_PROBE = 64;

comptime {
    std.debug.assert(SYMBOL_MAP_SIZE & (SYMBOL_MAP_SIZE - 1) == 0);
}

// ============================================================================
// Symbol Hash Table
// ============================================================================

const SymbolMapSlot = struct {
    symbol: msg.Symbol,
    book_index: i32, // -1 = empty
};

const SymbolMap = struct {
    slots: [SYMBOL_MAP_SIZE]SymbolMapSlot = undefined,
    count: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        for (&self.slots) |*slot| {
            slot.symbol = [_]u8{0} ** msg.MAX_SYMBOL_LENGTH;
            slot.book_index = -1;
        }
        return self;
    }

    /// FNV-1a hash for symbol
    fn hash(symbol: msg.Symbol) u32 {
        var h: u32 = 2166136261;
        for (symbol) |c| {
            if (c == 0) break;
            h ^= c;
            h *%= 16777619;
        }
        return h & SYMBOL_MAP_MASK;
    }

    pub fn find(self: *const Self, symbol: msg.Symbol) ?i32 {
        var idx = hash(symbol);
        
        for (0..MAX_SYMBOL_PROBE) |_| {
            const slot = &self.slots[idx];
            if (slot.book_index == -1 and slot.symbol[0] == 0) return null;
            if (msg.symbolEqual(slot.symbol, symbol)) return slot.book_index;
            idx = (idx + 1) & SYMBOL_MAP_MASK;
        }
        return null;
    }

    pub fn insert(self: *Self, symbol: msg.Symbol, book_index: i32) bool {
        var idx = hash(symbol);
        
        for (0..MAX_SYMBOL_PROBE) |_| {
            const slot = &self.slots[idx];
            if (slot.book_index == -1) {
                slot.symbol = symbol;
                slot.book_index = book_index;
                self.count += 1;
                return true;
            }
            idx = (idx + 1) & SYMBOL_MAP_MASK;
        }
        return false;
    }
};

// ============================================================================
// Order-to-Symbol Map (for cancels without symbol)
// ============================================================================

pub const ORDER_SYMBOL_MAP_SIZE = 16384;
pub const ORDER_SYMBOL_MAP_MASK = ORDER_SYMBOL_MAP_SIZE - 1;
pub const ORDER_KEY_EMPTY: u64 = 0;
pub const ORDER_KEY_TOMBSTONE: u64 = std.math.maxInt(u64);

const OrderSymbolSlot = struct {
    order_key: u64, // (user_id << 32) | user_order_id
    symbol: msg.Symbol,
};

const OrderSymbolMap = struct {
    slots: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot = undefined,
    count: u32 = 0,
    tombstone_count: u32 = 0,

    const Self = @This();

    pub fn init() Self {
        var self = Self{};
        for (&self.slots) |*slot| {
            slot.order_key = ORDER_KEY_EMPTY;
        }
        return self;
    }

    fn hash(key: u64) u32 {
        const GOLDEN: u64 = 0x9E3779B97F4A7C15;
        var k = key;
        k ^= k >> 33;
        k *%= GOLDEN;
        k ^= k >> 29;
        return @intCast(k & ORDER_SYMBOL_MAP_MASK);
    }

    pub fn insert(self: *Self, key: u64, symbol: msg.Symbol) bool {
        var idx = hash(key);
        
        for (0..128) |_| {
            const k = self.slots[idx].order_key;
            if (k == ORDER_KEY_EMPTY or k == ORDER_KEY_TOMBSTONE) {
                self.slots[idx] = .{ .order_key = key, .symbol = symbol };
                self.count += 1;
                return true;
            }
            idx = (idx + 1) & ORDER_SYMBOL_MAP_MASK;
        }
        return false;
    }

    pub fn find(self: *const Self, key: u64) ?msg.Symbol {
        var idx = hash(key);
        
        for (0..128) |_| {
            const slot = &self.slots[idx];
            if (slot.order_key == ORDER_KEY_EMPTY) return null;
            if (slot.order_key == key) return slot.symbol;
            idx = (idx + 1) & ORDER_SYMBOL_MAP_MASK;
        }
        return null;
    }

    pub fn remove(self: *Self, key: u64) bool {
        var idx = hash(key);
        
        for (0..128) |_| {
            if (self.slots[idx].order_key == ORDER_KEY_EMPTY) return false;
            if (self.slots[idx].order_key == key) {
                self.slots[idx].order_key = ORDER_KEY_TOMBSTONE;
                self.count -= 1;
                self.tombstone_count += 1;
                return true;
            }
            idx = (idx + 1) & ORDER_SYMBOL_MAP_MASK;
        }
        return false;
    }
};

// ============================================================================
// Matching Engine
// ============================================================================

pub const MatchingEngine = struct {
    symbol_map: SymbolMap,
    order_to_symbol: OrderSymbolMap,
    books: [MAX_SYMBOLS]OrderBook = undefined,
    num_books: usize = 0,
    pools: *MemoryPools,

    const Self = @This();

    pub fn init(pools: *MemoryPools) Self {
        return .{
            .symbol_map = SymbolMap.init(),
            .order_to_symbol = OrderSymbolMap.init(),
            .pools = pools,
        };
    }

    /// Process an input message
    pub fn processMessage(
        self: *Self,
        input: *const msg.InputMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        switch (input.msg_type) {
            .new_order => self.processNewOrder(&input.data.new_order, client_id, output),
            .cancel => self.processCancel(&input.data.cancel, client_id, output),
            .flush => self.processFlush(output),
        }
    }

    /// Process new order
    pub fn processNewOrder(
        self: *Self,
        order_msg: *const msg.NewOrderMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        // Get or create order book
        const book = self.getOrCreateBook(order_msg.symbol) orelse {
            output.add(msg.OutputMsg.makeReject(
                order_msg.user_id, order_msg.user_order_id,
                .unknown_symbol, client_id,
            ));
            return;
        };
        
        // Track order→symbol mapping for cancels
        const key = (@as(u64, order_msg.user_id) << 32) | order_msg.user_order_id;
        _ = self.order_to_symbol.insert(key, order_msg.symbol);
        
        // Process order
        book.addOrder(order_msg, client_id, output);
    }

    /// Process cancel
    pub fn processCancel(
        self: *Self,
        cancel_msg: *const msg.CancelMsg,
        client_id: u32,
        output: *OutputBuffer,
    ) void {
        // Find symbol for this order
        const key = (@as(u64, cancel_msg.user_id) << 32) | cancel_msg.user_order_id;
        
        // Try explicit symbol first, then lookup
        var symbol = cancel_msg.symbol;
        if (symbol[0] == 0) {
            symbol = self.order_to_symbol.find(key) orelse {
                output.add(msg.OutputMsg.makeReject(
                    cancel_msg.user_id, cancel_msg.user_order_id,
                    .order_not_found, client_id,
                ));
                return;
            };
        }
        
        // Get book
        if (self.getBook(symbol)) |book| {
            book.cancelOrder(
                cancel_msg.user_id,
                cancel_msg.user_order_id,
                client_id,
                output,
            );
            _ = self.order_to_symbol.remove(key);
        } else {
            output.add(msg.OutputMsg.makeReject(
                cancel_msg.user_id, cancel_msg.user_order_id,
                .unknown_symbol, client_id,
            ));
        }
    }

    /// Process flush (clear all books)
    pub fn processFlush(self: *Self, output: *OutputBuffer) void {
        _ = output;
        // TODO: Implement iterative flush
        self.order_to_symbol = OrderSymbolMap.init();
        
        for (self.books[0..self.num_books]) |*book| {
            book.* = OrderBook.init(book.symbol, self.pools);
        }
    }

    /// Get existing book for symbol
    fn getBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        if (self.symbol_map.find(symbol)) |idx| {
            return &self.books[@intCast(idx)];
        }
        return null;
    }

    /// Get or create book for symbol
    fn getOrCreateBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        // Check existing
        if (self.symbol_map.find(symbol)) |idx| {
            return &self.books[@intCast(idx)];
        }
        
        // Create new
        if (self.num_books >= MAX_SYMBOLS) return null;
        
        const idx = self.num_books;
        self.books[idx] = OrderBook.init(symbol, self.pools);
        _ = self.symbol_map.insert(symbol, @intCast(idx));
        self.num_books += 1;
        
        return &self.books[idx];
    }
};
