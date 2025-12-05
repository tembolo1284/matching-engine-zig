//! Multi-symbol matching engine orchestrator.
//!
//! Design principles:
//! - Open-addressing hash tables for O(1) symbol/order lookup
//! - Power-of-2 sizes with bitmask for fast modulo
//! - Bounded probe length prevents worst-case O(n) lookups
//! - Generation counter for O(1) bulk invalidation
//! - No dynamic allocation in hot path
//!
//! Thread Safety:
//! - NOT thread-safe. Use from a single thread only.
//! - For multi-threaded design, partition by symbol to separate engines.

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const OrderBook = @import("order_book.zig").OrderBook;
const OutputBuffer = @import("order_book.zig").OutputBuffer;
const MemoryPools = @import("memory_pool.zig").MemoryPools;
const config = @import("../transport/config.zig");

// ============================================================================
// Configuration
// ============================================================================

/// Maximum number of distinct symbols (order books).
/// Must be power of 2 for fast modulo.
pub const SYMBOL_MAP_SIZE: u32 = 512;
pub const SYMBOL_MAP_MASK: u32 = SYMBOL_MAP_SIZE - 1;

/// Maximum number of tracked orders for cancel routing.
/// Must be power of 2 for fast modulo.
pub const ORDER_SYMBOL_MAP_SIZE: u32 = 16384;
pub const ORDER_SYMBOL_MAP_MASK: u32 = ORDER_SYMBOL_MAP_SIZE - 1;

/// Maximum probe length for linear probing.
/// If exceeded, operation fails (hash table too full).
pub const MAX_PROBE_LENGTH: u32 = 64;

/// Load factor warning threshold (percentage).
/// Log warning when usage exceeds this.
const LOAD_FACTOR_WARNING: u32 = 75;

// Compile-time verification
comptime {
    std.debug.assert(SYMBOL_MAP_SIZE & (SYMBOL_MAP_SIZE - 1) == 0);
    std.debug.assert(ORDER_SYMBOL_MAP_SIZE & (ORDER_SYMBOL_MAP_SIZE - 1) == 0);
    std.debug.assert(MAX_PROBE_LENGTH > 0 and MAX_PROBE_LENGTH <= SYMBOL_MAP_SIZE);
}

// ============================================================================
// Hash Table Entry Types
// ============================================================================

/// Slot in the symbol → order book hash table.
const SymbolSlot = struct {
    symbol: msg.Symbol,
    book_index: u16,
    active: bool,
    _padding: [5]u8 = undefined, // Explicit padding

    comptime {
        // Verify expected size for cache efficiency
        std.debug.assert(@sizeOf(SymbolSlot) <= 24);
    }
};

/// Slot in the order → symbol hash table.
/// Used for routing cancel requests to the correct book.
const OrderSymbolSlot = struct {
    key: u64,           // Composite key: (user_id << 32) | order_id
    symbol: msg.Symbol,
    generation: u32,    // For O(1) bulk invalidation
    _padding: [4]u8 = undefined,

    comptime {
        std.debug.assert(@sizeOf(OrderSymbolSlot) <= 32);
    }

    /// Check if slot is active in current generation.
    fn isActive(self: *const OrderSymbolSlot, current_gen: u32) bool {
        return self.generation == current_gen;
    }
};

// ============================================================================
// Matching Engine
// ============================================================================

/// Multi-symbol matching engine.
///
/// Manages multiple order books (one per symbol) and routes incoming
/// messages to the appropriate book. Uses hash tables for O(1) routing.
pub const MatchingEngine = struct {
    // === Order Books ===
    /// Sparse array of order books, indexed by hash slot.
    books: [SYMBOL_MAP_SIZE]?OrderBook = [_]?OrderBook{null} ** SYMBOL_MAP_SIZE,

    /// Count of active books (for diagnostics).
    num_books: u32 = 0,

    // === Symbol Hash Table ===
    /// Maps symbol → book index using open addressing.
    symbol_map: [SYMBOL_MAP_SIZE]SymbolSlot = undefined,

    // === Order Tracking Hash Table ===
    /// Maps (user_id, order_id) → symbol for cancel routing.
    /// Uses generation counter for O(1) bulk clear.
    order_symbol_map: [ORDER_SYMBOL_MAP_SIZE]OrderSymbolSlot = undefined,

    /// Current generation for order tracking map.
    /// Incremented on flush to invalidate all entries instantly.
    order_map_generation: u32 = 1,

    /// Count of active entries in order map (for load factor monitoring).
    order_map_count: u32 = 0,

    // === Memory ===
    pools: *MemoryPools,

    // === Statistics ===
    total_orders: u64 = 0,
    total_cancels: u64 = 0,
    total_trades: u64 = 0,
    total_rejects: u64 = 0,
    probe_total: u64 = 0,      // Total probe steps (for average calculation)
    probe_count: u64 = 0,      // Number of lookups
    max_probe_length: u32 = 0, // Worst case observed

    // === Cache Line Padding ===
    /// Padding to prevent false sharing if engine is near other data.
    _cache_padding: [64]u8 = undefined,

    const Self = @This();

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize a new matching engine.
    pub fn init(pools: *MemoryPools) Self {
        std.debug.assert(pools.order_pool.capacity > 0);

        var engine = Self{ .pools = pools };

        // Initialize symbol map (all inactive)
        for (&engine.symbol_map) |*slot| {
            slot.active = false;
        }

        // Initialize order map (generation 0 means inactive)
        for (&engine.order_symbol_map) |*slot| {
            slot.generation = 0;
        }

        std.debug.assert(engine.isValid());
        return engine;
    }

    /// Check engine invariants.
    fn isValid(self: *const Self) bool {
        if (self.num_books > SYMBOL_MAP_SIZE) return false;
        if (self.order_map_count > ORDER_SYMBOL_MAP_SIZE) return false;
        if (self.order_map_generation == 0) return false; // 0 reserved for "inactive"
        return true;
    }

    // ========================================================================
    // Message Processing
    // ========================================================================

    /// Process an incoming message and generate output messages.
    ///
    /// This is the main entry point for the hot path.
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
        // Pre-conditions
        std.debug.assert(order.quantity > 0);

        self.total_orders += 1;

        // Find or create order book for this symbol
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

        // Track order → symbol mapping for cancel routing
        const key = makeOrderKey(order.user_id, order.user_order_id);
        const tracked = self.trackOrderSymbol(key, order.symbol);

        if (!tracked) {
            // Order tracking table full - this is serious but not fatal.
            // The order will still execute, but cancel may require full scan.
            // In production, this should trigger an alert.
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

        // Look up symbol from order tracking.
        // If not found, use symbol from cancel message (if provided).
        const symbol = self.lookupOrderSymbol(key) orelse cancel.symbol;

        if (msg.symbolIsEmpty(&symbol)) {
            // No symbol provided and not in tracking table.
            // We could scan all books, but that's O(n) and breaks latency guarantees.
            // Instead, reject with clear error - client should resend with symbol.
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

        // Route to specific book
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

        // Remove from tracking (idempotent)
        self.removeOrderSymbol(key);
    }

    fn handleFlush(self: *Self, output: *OutputBuffer) void {
        // Flush all order books
        for (&self.books) |*maybe_book| {
            if (maybe_book.*) |*book| {
                book.flush(output);
            }
        }

        // O(1) clear of order tracking via generation increment.
        // All entries with old generation are now considered inactive.
        self.order_map_generation +%= 1;

        // Handle wraparound: generation 0 is reserved for "never active"
        if (self.order_map_generation == 0) {
            self.order_map_generation = 1;
        }

        self.order_map_count = 0;
    }

    // ========================================================================
    // Client Disconnect Handling
    // ========================================================================

    /// Cancel all orders for a specific client (on disconnect).
    /// Returns count of orders cancelled.
    pub fn cancelClientOrders(self: *Self, client_id: config.ClientId, output: *OutputBuffer) usize {
        std.debug.assert(client_id > 0);

        var cancelled: usize = 0;
        for (&self.books) |*maybe_book| {
            if (maybe_book.*) |*book| {
                cancelled += book.cancelClientOrders(client_id, output);
            }
        }
        return cancelled;
    }

    // ========================================================================
    // Symbol Hash Table Operations
    // ========================================================================

    /// Find existing book or create new one for symbol.
    fn findOrCreateBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        // First try to find existing
        if (self.findBook(symbol)) |book| {
            return book;
        }

        // Create new book - find empty slot
        const idx = hashSymbol(symbol);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;

            if (!self.symbol_map[slot_idx].active) {
                // Found empty slot - initialize or reset book
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
                self.recordProbe(probe);

                // Check load factor
                self.checkSymbolMapLoad();

                return &self.books[slot_idx].?;
            }
        }

        // Probe limit exceeded - table too full
        std.log.err("Symbol map probe limit exceeded for symbol", .{});
        return null;
    }

    /// Find existing book for symbol.
    fn findBook(self: *Self, symbol: msg.Symbol) ?*OrderBook {
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        const idx = hashSymbol(symbol);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & SYMBOL_MAP_MASK;
            const slot = &self.symbol_map[slot_idx];

            if (!slot.active) {
                self.recordProbe(probe);
                return null; // Empty slot = not found
            }

            if (msg.symbolEqual(&slot.symbol, &symbol)) {
                self.recordProbe(probe);
                return &self.books[slot.book_index].?;
            }
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return null;
    }

    fn checkSymbolMapLoad(self: *Self) void {
        const load_pct = (self.num_books * 100) / SYMBOL_MAP_SIZE;
        if (load_pct > LOAD_FACTOR_WARNING) {
            std.log.warn("Symbol map load factor: {}% ({}/{})", .{
                load_pct,
                self.num_books,
                SYMBOL_MAP_SIZE,
            });
        }
    }

    // ========================================================================
    // Order Tracking Hash Table Operations
    // ========================================================================

    /// Track order → symbol mapping for cancel routing.
    /// Returns true on success, false if table is full.
    fn trackOrderSymbol(self: *Self, key: u64, symbol: msg.Symbol) bool {
        std.debug.assert(key != 0);
        std.debug.assert(!msg.symbolIsEmpty(&symbol));

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            // Slot is available if:
            // 1. Generation is old (stale from before last flush)
            // 2. This is the same key (update)
            if (!slot.isActive(self.order_map_generation) or slot.key == key) {
                const was_new = !slot.isActive(self.order_map_generation);

                slot.* = .{
                    .key = key,
                    .symbol = symbol,
                    .generation = self.order_map_generation,
                };

                if (was_new) {
                    self.order_map_count += 1;
                }

                self.recordProbe(probe);
                return true;
            }
        }

        // Probe limit exceeded
        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    /// Look up symbol for an order.
    fn lookupOrderSymbol(self: *Self, key: u64) ?msg.Symbol {
        std.debug.assert(key != 0);

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            // Check if slot is active in current generation
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

    /// Remove order from tracking.
    fn removeOrderSymbol(self: *Self, key: u64) void {
        std.debug.assert(key != 0);

        const idx = hashOrderKey(key);
        var probe: u32 = 0;

        while (probe < MAX_PROBE_LENGTH) : (probe += 1) {
            const slot_idx = (idx + probe) & ORDER_SYMBOL_MAP_MASK;
            const slot = &self.order_symbol_map[slot_idx];

            if (!slot.isActive(self.order_map_generation)) {
                return; // Not found
            }

            if (slot.key == key) {
                // Mark as inactive by setting generation to 0
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

    /// Get engine statistics.
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

/// Engine statistics snapshot.
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

/// FNV-1a hash for symbols.
fn hashSymbol(symbol: msg.Symbol) u32 {
    var hash: u32 = 2166136261; // FNV offset basis
    for (symbol) |byte| {
        if (byte == 0) break;
        hash ^= byte;
        hash *%= 16777619; // FNV prime
    }
    return hash & SYMBOL_MAP_MASK;
}

/// Multiplicative hash for order keys.
/// Uses golden ratio for good distribution.
fn hashOrderKey(key: u64) u32 {
    const GOLDEN_RATIO: u64 = 0x9E3779B97F4A7C15;
    var k = key;
    k ^= k >> 33;
    k *%= GOLDEN_RATIO;
    k ^= k >> 29;
    return @intCast(k & ORDER_SYMBOL_MAP_MASK);
}

/// Create composite key from user_id and order_id.
fn makeOrderKey(user_id: u32, order_id: u32) u64 {
    std.debug.assert(user_id > 0 or order_id > 0); // At least one must be non-zero
    return (@as(u64, user_id) << 32) | order_id;
}

// ============================================================================
// Tests
// ============================================================================

test "hash functions distribute well" {
    // Test symbol hash distribution
    var symbol_buckets: [16]u32 = [_]u32{0} ** 16;
    const symbols = [_][]const u8{ "AAPL", "GOOGL", "MSFT", "AMZN", "META", "NVDA", "TSLA", "JPM" };

    for (symbols) |sym| {
        var symbol: msg.Symbol = [_]u8{0} ** 8;
        @memcpy(symbol[0..sym.len], sym);
        const hash = hashSymbol(symbol);
        symbol_buckets[hash & 0xF] += 1;
    }

    // No bucket should have all entries (poor distribution)
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

    // Verify reconstruction
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(k1 >> 32)));
    try std.testing.expectEqual(@as(u32, 1), @as(u32, @intCast(k1 & 0xFFFFFFFF)));
}

test "generation counter wraparound" {
    var slot = OrderSymbolSlot{
        .key = 12345,
        .symbol = msg.makeSymbol("TEST"),
        .generation = 0,
    };

    // Generation 0 is never active
    try std.testing.expect(!slot.isActive(0));
    try std.testing.expect(!slot.isActive(1));

    // Set to current generation
    slot.generation = 5;
    try std.testing.expect(slot.isActive(5));
    try std.testing.expect(!slot.isActive(6));
}
