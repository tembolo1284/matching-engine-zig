//! Multi-symbol matching engine orchestrator.
//!
//! Design principles:
//! - Open-addressing hash tables for O(1) symbol/order lookup
//! - Power-of-2 sizes with bitmask for fast modulo
//! - Bounded probe length prevents worst-case O(n) lookups
//! - Generation counter for O(1) bulk invalidation
//! - No dynamic allocation in hot path
//!
//! Memory model:
//! - Engine struct uses pointers to heap-allocated OrderBooks
//! - Each OrderBook is ~7.5MB, allocated individually
//! - No stack temporaries for large structs
//!
//! Thread Safety:
//! - NOT thread-safe. Use from a single thread only.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const OrderBook = @import("order_book.zig").OrderBook;
const OutputBuffer = @import("order_book.zig").OutputBuffer;
const MemoryPools = @import("memory_pool.zig").MemoryPools;
const config = @import("../transport/config.zig");

// ============================================================================
// Configuration
// ============================================================================

pub const SYMBOL_MAP_SIZE: u32 = 512;
pub const SYMBOL_MAP_MASK: u32 = SYMBOL_MAP_SIZE - 1;

pub const ORDER_SYMBOL_MAP_SIZE: u32 = 16384;
pub const ORDER_SYMBOL_MAP_MASK: u32 = ORDER_SYMBOL_MAP_SIZE - 1;

pub const MAX_PROBE_LENGTH: u32 = 64;

const LOAD_FACTOR_WARNING: u32 = 75;

// ============================================================================
// Hash Table Entry Types
// ============================================================================

const SymbolSlot = struct {
    symbol: msg.Symbol,
    book_index: u16,
    active: bool,
    _padding: [5]u8,
};

const OrderSymbolSlot = struct {
    key: u64,
    symbol: msg.Symbol,
    generation: u32,
    _padding: [4]u8,

    fn isActive(self: *const OrderSymbolSlot, current_gen: u32) bool {
        return self.generation == current_gen;
    }
};

// ============================================================================
// Matching Engine
// ============================================================================

pub const MatchingEngine = struct {
    // === Order Books (pointers to heap-allocated books) ===
    // Using pointers avoids 7.5MB stack temporaries when creating books
    books: [SYMBOL_MAP_SIZE]?*OrderBook,
    num_books: u32,

    // === Symbol Hash Table ===
    symbol_map: [SYMBOL_MAP_SIZE]SymbolSlot,

    // === Order Tracking Hash Table ===
    order_symbol_map: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot,
    order_map_generation: u32,
    order_map_count: u32,

    // === Memory ===
    pools: *MemoryPools,
    allocator: std.mem.Allocator,

    // === Statistics ===
    total_orders: u64,
    total_cancels: u64,
    total_trades: u64,
    total_rejects: u64,
    probe_total: u64,
    probe_count: u64,
    max_probe_length: u32,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize engine in-place. MUST be called on heap-allocated memory!
    pub fn initInPlace(self: *Self, pools: *MemoryPools) void {
        std.debug.assert(pools.order_pool.capacity > 0);

        self.pools = pools;
        self.allocator = pools.order_pool.allocator;
        self.num_books = 0;
        self.order_map_generation = 1;
        self.order_map_count = 0;
        self.total_orders = 0;
        self.total_cancels = 0;
        self.total_trades = 0;
        self.total_rejects = 0;
        self.probe_total = 0;
        self.probe_count = 0;
        self.max_probe_length = 0;

        // Initialize books array (all null pointers)
        for (&self.books) |*book| {
            book.* = null;
        }

        // Initialize symbol map (all inactive)
        for (&self.symbol_map) |*slot| {
            slot.active = false;
            slot.symbol = msg.EMPTY_SYMBOL;
            slot.book_index = 0;
            slot._padding = undefined;
        }

        // Initialize order map (generation 0 means inactive)
        for (&self.order_symbol_map) |*slot| {
            slot.generation = 0;
            slot.key = 0;
            slot.symbol = msg.EMPTY_SYMBOL;
            slot._padding = undefined;
        }

        std.debug.assert(self.isValid());
    }

    /// Legacy init for compatibility.
    pub fn init(pools: *MemoryPools) Self {
        var engine: Self = undefined;
        engine.initInPlace(pools);
        return engine;
    }

    /// Cleanup - release all heap-allocated OrderBooks.
    pub fn deinit(self: *Self) void {
        for (&self.books) |*book_ptr| {
            if (book_ptr.*) |book| {
                self.allocator.destroy(book);
                book_ptr.* = null;
            }
        }
    }

    fn isValid(self: *const Self) bool {
        if (self.num_books > SYMBOL_MAP_SIZE) return false;
        if (self.order_map_count > ORDER_SYMBOL_MAP_SIZE) return false;
        if (self.order_map_generation == 0) return false;
        return true;
    }

    // ========================================================================
    // Message Processing
    // ========================================================================

    pub fn processMessage(
        self: *Self,
        message: *const msg.InputMsg,
        client_id: config.ClientId,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(self.isValid());

        switch (message.msg_type) {
            .new_order => self.handleNewOrder(&message.data.new_order, client_id, output),
            .cancel => self.handleCancel(&message.data.cancel, client_id, output),
            .flush => self.handleFlush(output),
        }

        std.debug.assert(self.isValid());
    }

    // ========================================================================
    // Order Handling
    // ========================================================================

    fn handleNewOrder(
        self: *Self,
        order: *const msg.NewOrderMsg,
        client_id: config.ClientId,
        output: *OutputBuffer,
    ) void {
        std.debug.assert(order.quantity > 0);

        self.total_orders += 1;

        const book = self.findOrCreateBook(order.symbol) orelse {
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                order.user_id,
                order.user_order_id,
                .unknown_symbol,
                order.symbol,
                client_id,
            ));
            return;
        };

        const key = makeOrderKey(order.user_id, order.user_order_id);
        const tracked = self.trackOrderSymbol(key, order.symbol);
        if (!tracked) {
            std.log.warn("Order tracking table full, cancel routing degraded", .{});
        }

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
        const symbol = self.lookupOrderSymbol(key) orelse cancel.symbol;

        if (msg.symbolIsEmpty(&symbol)) {
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                cancel.user_id,
                cancel.user_order_id,
                .order_not_found,
                symbol,
                client_id,
            ));
            return;
        }

        if (self.findBook(symbol)) |book| {
            book.cancelOrder(cancel.user_id, cancel.user_order_id, client_id, output);
        } else {
            self.total_rejects += 1;
            _ = output.add(msg.OutputMsg.makeReject(
                cancel.user_id,
                cancel.user_order_id,
                .order_not_found,
                symbol,
                client_id,
            ));
        }

        self.removeOrderSymbol(key);
    }

    fn handleFlush(self: *Self, output: *OutputBuffer) void {
        for (self.books) |maybe_book| {
            if (maybe_book) |book| {
                book.flush(output);
            }
        }

        self.order_map_generation +%= 1;
        if (self.order_map_generation == 0) {
            self.order_map_generation = 1;
        }
        self.order_map_count = 0;
    }

    // ========================================================================
    // Client Disconnect Handling
    // ========================================================================

    pub fn cancelClientOrders(self: *Self, client_id: config.ClientId, output: *OutputBuffer) usize {
        std.debug.assert(client_id > 0);

        var cancelled: usize = 0;
        for (self.books) |maybe_book| {
            if (maybe_book) |book| {
                cancelled += book.cancelClientOrders(client_id, output);
            }
        }
        return cancelled;
    }

    // ========================================================================
    // Symbol Hash Table Operations
    // ========================================================================

    fn findOrCreateBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        if (self.findBook(symbol)) |book| {
            return book;
        }

        const idx = hashSymbol(symbol);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;

            if (!self.symbol_map[slot_idx].active) {
                // Heap-allocate a new OrderBook if needed
                if (self.books[slot_idx] == null) {
                    const book = self.allocator.create(OrderBook) catch {
                        std.log.err("Failed to allocate OrderBook", .{});
                        return null;
                    };
                    book.initInPlace(symbol, self.pools);
                    self.books[slot_idx] = book;
                } else {
                    // Reuse existing book, reinitialize for new symbol
                    self.books[slot_idx].?.initInPlace(symbol, self.pools);
                }

                self.symbol_map[slot_idx] = .{
                    .symbol = symbol,
                    .book_index = @intCast(slot_idx),
                    .active = true,
                    ._padding = undefined,
                };

                self.num_books += 1;
                self.recordProbe(probe);
                self.checkSymbolMapLoad();

                return self.books[slot_idx];
            }
        }

        std.log.err("Symbol map probe limit exceeded for symbol", .{});
        return null;
    }

    fn findBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        const idx = hashSymbol(symbol);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;
            const slot = &self.symbol_map[slot_idx];

            if (!slot.active) {
                self.recordProbe(probe);
                return null;
            }

            if (msg.symbolEqual(&slot.symbol, &symbol)) {
                self.recordProbe(probe);
                return self.books[slot.book_index];
            }
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return null;
    }

    fn checkSymbolMapLoad(self: *Self) void {
        const load_pct = (self.num_books * 100) / SYMBOL_MAP_SIZE;
        if (load_pct > LOAD_FACTOR_WARNING) {
            std.log.warn("Symbol map load factor: {d}% ({d}/{d})", .{
                load_pct,
                self.num_books,
                SYMBOL_MAP_SIZE,
            });
        }
    }

    // ========================================================================
    // Order Tracking Hash Table Operations
    // ========================================================================

    fn trackOrderSymbol(self: *Self, key: u64, symbol: msg.Symbol) bool {
        std.debug.assert(key != 0);
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.isActive(self.order_map_generation) or slot.key == key) {
                const was_new = !slot.isActive(self.order_map_generation);
                slot.* = .{
                    .key = key,
                    .symbol = symbol,
                    .generation = self.order_map_generation,
                    ._padding = undefined,
                };

                if (was_new) {
                    self.order_map_count += 1;
                }

                self.recordProbe(probe);
                return true;
            }
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    fn lookupOrderSymbol(self: *Self, key: u64) ?msg.Symbol {
        std.debug.assert(key != 0);

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.isActive(self.order_map_generation)) {
                self.recordProbe(probe);
                return null;
            }

            if (slot.key == key) {
                self.recordProbe(probe);
                return slot.symbol;
            }
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return null;
    }

    fn removeOrderSymbol(self: *Self, key: u64) void {
        std.debug.assert(key != 0);

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.isActive(self.order_map_generation)) {
                return;
            }

            if (slot.key == key) {
                slot.generation = 0;
                std.debug.assert(self.order_map_count > 0);
                self.order_map_count -= 1;
                return;
            }
        }
    }

    // ========================================================================
    // Statistics
    // ========================================================================

    fn recordProbe(self: *Self, probe_length: u32) void {
        self.probe_total += probe_length;
        self.probe_count += 1;
        self.max_probe_length = @max(self.max_probe_length, probe_length);
    }

    pub fn getStats(self: *const Self) EngineStats {
        const avg_probe = if (self.probe_count > 0)
            @as(f32, @floatFromInt(self.probe_total)) / @as(f32, @floatFromInt(self.probe_count))
        else
            0.0;

        return .{
            .total_orders = self.total_orders,
            .total_cancels = self.total_cancels,
            .total_trades = self.total_trades,
            .total_rejects = self.total_rejects,
            .num_books = self.num_books,
            .order_map_count = self.order_map_count,
            .order_map_generation = self.order_map_generation,
            .avg_probe_length = avg_probe,
            .max_probe_length = self.max_probe_length,
        };
    }
};

pub const EngineStats = struct {
    total_orders: u64,
    total_cancels: u64,
    total_trades: u64,
    total_rejects: u64,
    num_books: u32,
    order_map_count: u32,
    order_map_generation: u32,
    avg_probe_length: f32,
    max_probe_length: u32,
};

// ============================================================================
// Hash Functions
// ============================================================================

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
    std.debug.assert(user_id > 0 or order_id > 0);
    return (@as(u64, user_id) << 32) | order_id;
}

// ============================================================================
// Tests
// ============================================================================

test "hash functions distribute well" {
    var symbol_buckets: [16]u32 = [_]u32{0} ** 16;
    const symbols = [_][]const u8{ "AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "TSLA", "JPM" };

    for (symbols) |sym| {
        var symbol: msg.Symbol = [_]u8{0} ** 8;
        @memcpy(symbol[0..sym.len], sym);
        const hash = hashSymbol(symbol);
        symbol_buckets[hash & 0xF] += 1;
    }

    for (symbol_buckets) |count| {
        try std.testing.expect(count < symbols.len);
    }
}

test "makeOrderKey uniqueness" {
    const k1 = makeOrderKey(1, 1);
    const k2 = makeOrderKey(1, 2);
    const k3 = makeOrderKey(2, 1);

    try std.testing.expect(k1 != k2);
    try std.testing.expect(k1 != k3);
    try std.testing.expect(k2 != k3);
}
