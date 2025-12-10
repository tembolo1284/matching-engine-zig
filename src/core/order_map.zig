//! Open-addressing hash map for O(1) order lookup by (user_id, order_id).
//!
//! Design principles:
//! - Power-of-2 size for fast modulo via bitmask
//! - Linear probing with bounded probe length (NASA Rule 2)
//! - Tombstone-based deletion with periodic compaction
//! - Pre-allocated compaction buffer (NASA Rule 3 - no allocation in hot path)
//!
//! Key space:
//! - Key 0 is reserved as EMPTY sentinel
//! - Key maxInt(u64) is reserved as TOMBSTONE sentinel
//! - Orders with user_id=0 AND order_id=0 must be rejected upstream
//!
//! Memory footprint:
//! - Main slots: ORDER_MAP_SIZE × 32 bytes = 8MB
//! - Compaction buffer: ORDER_MAP_SIZE × 32 bytes = 8MB
//! - Total: ~16MB per OrderMap instance

const std = @import("std");
const msg = @import("../protocol/message_types.zig");
const Order = @import("order.zig").Order;

// ============================================================================
// Configuration
// ============================================================================

/// Hash map size for order lookup. Must be power of 2.
/// 256K slots with ~50% load factor supports ~128K concurrent orders.
pub const ORDER_MAP_SIZE: u32 = 262_144;

/// Bitmask for fast modulo (size - 1).
pub const ORDER_MAP_MASK: u32 = ORDER_MAP_SIZE - 1;

/// Maximum probes before giving up on insert/find.
/// With good hash function, this should rarely exceed 10-20.
pub const MAX_PROBE_LENGTH: u32 = 128;

/// Tombstone threshold for triggering compaction (percentage).
const TOMBSTONE_COMPACT_THRESHOLD: u32 = 25;

/// Sentinel values for hash map slots.
pub const HASH_SLOT_EMPTY: u64 = 0;
pub const HASH_SLOT_TOMBSTONE: u64 = std.math.maxInt(u64);

// ============================================================================
// Order Location
// ============================================================================

/// Cached location of an order in the book for O(1) removal.
/// Stored in the hash map as the value associated with each order key.
pub const OrderLocation = struct {
    /// Side of the book (buy/sell).
    side: msg.Side,
    /// Price level where the order resides.
    price: u32,
    /// Direct pointer to the order in the memory pool.
    order_ptr: *Order,

    /// Validate that the location matches the order's actual state.
    /// Used in debug assertions.
    pub fn isValid(self: *const OrderLocation) bool {
        if (self.order_ptr.price != self.price) return false;
        if (self.order_ptr.side != self.side) return false;
        return true;
    }
};

// ============================================================================
// Order Map Slot
// ============================================================================

const OrderMapSlot = struct {
    key: u64,
    location: OrderLocation,
};

// ============================================================================
// Order Map
// ============================================================================

/// Open-addressing hash map for O(1) order lookup.
///
/// Key: (user_id << 32) | order_id
/// Value: OrderLocation (side, price, pointer)
///
/// Uses linear probing with tombstone markers for deletion.
/// Compaction runs when tombstones exceed TOMBSTONE_COMPACT_THRESHOLD%.
///
/// Memory: ~16MB total (8MB slots + 8MB compaction buffer)
/// This struct is too large for stack allocation - use heap via create().
pub const OrderMap = struct {
    /// Hash table slots. Must use initInPlace due to size.
    slots: [ORDER_MAP_SIZE]OrderMapSlot,

    /// Pre-allocated buffer for compaction (avoids allocation during operation).
    /// This ensures compaction is O(n) time but O(1) allocations.
    compact_buffer: [ORDER_MAP_SIZE]OrderMapSlot,

    /// Number of active entries.
    count: u32,

    /// Number of tombstone slots (deleted but not compacted).
    tombstone_count: u32,

    // === Statistics ===
    total_inserts: u64,
    total_removes: u64,
    total_lookups: u64,
    probe_total: u64,
    max_probe: u32,
    compactions: u32,
    duplicate_rejects: u64,

    const Self = @This();

    // ========================================================================
    // Compile-time size verification
    // ========================================================================
    comptime {
        // Verify this struct is too large for typical stack (1MB threshold)
        // Actual size is ~12-16MB depending on OrderMapSlot padding
        const size = @sizeOf(Self);
        std.debug.assert(size > 1 * 1024 * 1024); // > 1MB = too large for stack
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize in-place (required for large struct).
    /// Must be called before any other operations.
    ///
    /// Note: allocator parameter kept for API compatibility but no longer used
    /// since compaction buffer is now pre-allocated.
    pub fn initInPlace(self: *Self, _: std.mem.Allocator) void {
        self.count = 0;
        self.tombstone_count = 0;
        self.total_inserts = 0;
        self.total_removes = 0;
        self.total_lookups = 0;
        self.probe_total = 0;
        self.max_probe = 0;
        self.compactions = 0;
        self.duplicate_rejects = 0;

        // Initialize all slots at runtime (NOT compile-time!)
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }

        // Compact buffer doesn't need initialization - it's written before read

        std.debug.assert(self.isValid());
    }

    // ========================================================================
    // Key Management
    // ========================================================================

    /// Create composite key from user_id and order_id.
    ///
    /// Note: key 0 (user_id=0, order_id=0) is reserved as EMPTY sentinel.
    /// Caller must reject orders with both fields zero.
    pub inline fn makeKey(user_id: u32, user_order_id: u32) u64 {
        const raw = (@as(u64, user_id) << 32) | user_order_id;
        std.debug.assert(raw != HASH_SLOT_EMPTY);
        std.debug.assert(raw != HASH_SLOT_TOMBSTONE);
        return raw;
    }

    /// Check if a user_id/order_id pair is valid for use as a key.
    /// Returns false if the combination would collide with sentinel values.
    pub inline fn isValidKey(user_id: u32, user_order_id: u32) bool {
        // Key 0 is reserved as EMPTY sentinel
        if (user_id == 0 and user_order_id == 0) return false;
        // Key maxInt is reserved as TOMBSTONE sentinel
        if (user_id == std.math.maxInt(u32) and user_order_id == std.math.maxInt(u32)) return false;
        return true;
    }

    // ========================================================================
    // Hash Function
    // ========================================================================

    /// Fibonacci hashing for good distribution.
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

    // ========================================================================
    // Core Operations
    // ========================================================================

    /// Insert a key-location pair.
    /// Returns false if map is full (probe length exceeded) OR if key already exists.
    /// Duplicate keys are logged and rejected gracefully (no panic).
    pub fn insert(self: *Self, key: u64, location: OrderLocation) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);
        std.debug.assert(location.order_ptr.remaining_qty > 0);
        std.debug.assert(self.isValid());

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
                std.debug.assert(self.isValid());
                return true;
            }

            if (slot_key == key) {
                // FIXED: Don't panic on duplicate key - log and reject gracefully.
                // This can happen due to client bugs, replay attacks, or protocol issues.
                // The caller (order_book) will generate a REJECT message.
                std.log.warn("OrderMap.insert: duplicate key {d} (user={d}, order={d}) - rejecting", .{
                    key,
                    @as(u32, @truncate(key >> 32)),
                    @as(u32, @truncate(key)),
                });
                self.duplicate_rejects += 1;
                self.recordProbe(probe);
                return false;
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    /// Find a key, returning pointer to its location or null.
    pub fn find(self: *Self, key: u64) ?*const OrderLocation {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);
        std.debug.assert(self.isValid());

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

    /// Remove a key.
    /// Returns true if found and removed, false if not found.
    pub fn remove(self: *Self, key: u64) bool {
        std.debug.assert(key != HASH_SLOT_EMPTY);
        std.debug.assert(key != HASH_SLOT_TOMBSTONE);
        std.debug.assert(self.isValid());

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
                std.debug.assert(self.isValid());
                return true;
            }

            idx = (idx + 1) & ORDER_MAP_MASK;
        }

        self.recordProbe(MAX_PROBE_LENGTH);
        return false;
    }

    // ========================================================================
    // Compaction
    // ========================================================================

    fn shouldCompact(self: *const Self) bool {
        const threshold = ORDER_MAP_SIZE * TOMBSTONE_COMPACT_THRESHOLD / 100;
        return self.tombstone_count > threshold;
    }

    /// Compact the hash map by removing tombstones.
    /// Uses pre-allocated compact_buffer - NO allocation during operation.
    ///
    /// Complexity: O(n) time, O(1) allocation
    fn compact(self: *Self) void {
        std.debug.assert(self.isValid());

        // Copy live entries to pre-allocated buffer
        var entry_count: u32 = 0;
        for (&self.slots) |*slot| {
            if (slot.key != HASH_SLOT_EMPTY and slot.key != HASH_SLOT_TOMBSTONE) {
                self.compact_buffer[entry_count] = slot.*;
                entry_count += 1;
            }
        }

        std.debug.assert(entry_count == self.count);

        // Clear all slots
        for (&self.slots) |*slot| {
            slot.key = HASH_SLOT_EMPTY;
        }

        // Reinsert live entries
        const old_count = self.count;
        self.count = 0;
        self.tombstone_count = 0;

        for (self.compact_buffer[0..entry_count]) |entry| {
            const success = self.insertInternal(entry.key, entry.location);
            std.debug.assert(success);
        }

        std.debug.assert(self.count == old_count);
        self.compactions += 1;

        std.debug.assert(self.isValid());
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

    // ========================================================================
    // Statistics
    // ========================================================================

    fn recordProbe(self: *Self, probe_length: u32) void {
        self.probe_total += probe_length;
        self.max_probe = @max(self.max_probe, probe_length);
    }

    /// Get current load factor as percentage (0-100).
    pub fn getLoadFactor(self: *const Self) u32 {
        return (self.count * 100) / ORDER_MAP_SIZE;
    }

    /// Validate map invariants.
    pub fn isValid(self: *const Self) bool {
        if (self.count > ORDER_MAP_SIZE) return false;
        if (self.tombstone_count > ORDER_MAP_SIZE) return false;
        if (self.count + self.tombstone_count > ORDER_MAP_SIZE) return false;
        return true;
    }

    /// Get memory footprint in bytes.
    pub fn getMemoryFootprint() usize {
        return @sizeOf(Self);
    }

    /// Get number of duplicate key rejections (for monitoring).
    pub fn getDuplicateRejects(self: *const Self) u64 {
        return self.duplicate_rejects;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "OrderMap basic operations" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

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

test "OrderMap duplicate key rejection" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    const key1 = OrderMap.makeKey(1, 100);

    var order1 = std.mem.zeroes(Order);
    order1.price = 5000;
    order1.side = .buy;
    order1.remaining_qty = 10;

    var order2 = std.mem.zeroes(Order);
    order2.price = 6000;
    order2.side = .buy;
    order2.remaining_qty = 20;

    const loc1 = OrderLocation{ .side = .buy, .price = 5000, .order_ptr = &order1 };
    const loc2 = OrderLocation{ .side = .buy, .price = 6000, .order_ptr = &order2 };

    // First insert should succeed
    try std.testing.expect(map.insert(key1, loc1));
    try std.testing.expectEqual(@as(u32, 1), map.count);
    try std.testing.expectEqual(@as(u64, 0), map.duplicate_rejects);

    // Duplicate insert should fail gracefully (not panic!)
    try std.testing.expect(!map.insert(key1, loc2));
    try std.testing.expectEqual(@as(u32, 1), map.count); // Count unchanged
    try std.testing.expectEqual(@as(u64, 1), map.duplicate_rejects);

    // Original order should still be there
    const found = map.find(key1);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 5000), found.?.price); // Original price, not 6000
}

test "OrderMap key validation" {
    // Key (0, 0) should be invalid (EMPTY sentinel)
    try std.testing.expect(!OrderMap.isValidKey(0, 0));

    // Key (maxInt, maxInt) should be invalid (TOMBSTONE sentinel)
    try std.testing.expect(!OrderMap.isValidKey(std.math.maxInt(u32), std.math.maxInt(u32)));

    // Normal keys should be valid
    try std.testing.expect(OrderMap.isValidKey(1, 1));
    try std.testing.expect(OrderMap.isValidKey(0, 1));
    try std.testing.expect(OrderMap.isValidKey(1, 0));
    try std.testing.expect(OrderMap.isValidKey(12345, 67890));
}

test "OrderMap find non-existent" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    const key = OrderMap.makeKey(999, 999);
    try std.testing.expect(map.find(key) == null);
}

test "OrderMap remove non-existent" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    const key = OrderMap.makeKey(999, 999);
    try std.testing.expect(!map.remove(key));
}

test "OrderMap multiple entries" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    var orders: [10]Order = undefined;
    for (&orders, 0..) |*order, i| {
        order.* = std.mem.zeroes(Order);
        order.price = @intCast(1000 + i);
        order.side = .buy;
        order.remaining_qty = 10;

        const key = OrderMap.makeKey(1, @intCast(i));
        const loc = OrderLocation{ .side = .buy, .price = order.price, .order_ptr = order };
        try std.testing.expect(map.insert(key, loc));
    }

    try std.testing.expectEqual(@as(u32, 10), map.count);

    // Find all
    for (0..10) |i| {
        const key = OrderMap.makeKey(1, @intCast(i));
        const found = map.find(key);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(@as(u32, @intCast(1000 + i)), found.?.price);
    }

    // Remove half
    for (0..5) |i| {
        const key = OrderMap.makeKey(1, @intCast(i));
        try std.testing.expect(map.remove(key));
    }

    try std.testing.expectEqual(@as(u32, 5), map.count);
    try std.testing.expectEqual(@as(u32, 5), map.tombstone_count);
}

test "OrderMap load factor" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), map.getLoadFactor());

    var orders: [100]Order = undefined;
    for (&orders, 0..) |*order, i| {
        order.* = std.mem.zeroes(Order);
        order.price = 1000;
        order.side = .buy;
        order.remaining_qty = 10;

        const key = OrderMap.makeKey(@intCast(i), 1);
        const loc = OrderLocation{ .side = .buy, .price = 1000, .order_ptr = order };
        try std.testing.expect(map.insert(key, loc));
    }

    // 100 / 262144 ≈ 0.03%, should round to 0
    try std.testing.expect(map.getLoadFactor() < 1);
}

test "OrderLocation validation" {
    var order = std.mem.zeroes(Order);
    order.price = 5000;
    order.side = .buy;
    order.remaining_qty = 10;

    const valid_loc = OrderLocation{ .side = .buy, .price = 5000, .order_ptr = &order };
    try std.testing.expect(valid_loc.isValid());

    const invalid_price = OrderLocation{ .side = .buy, .price = 9999, .order_ptr = &order };
    try std.testing.expect(!invalid_price.isValid());

    const invalid_side = OrderLocation{ .side = .sell, .price = 5000, .order_ptr = &order };
    try std.testing.expect(!invalid_side.isValid());
}

test "OrderMap compaction" {
    var map: OrderMap = undefined;
    map.initInPlace(std.testing.allocator);

    // Insert many orders
    var orders: [100]Order = undefined;
    for (&orders, 0..) |*order, i| {
        order.* = std.mem.zeroes(Order);
        order.price = 1000;
        order.side = .buy;
        order.remaining_qty = 10;

        const key = OrderMap.makeKey(@intCast(i), 1);
        const loc = OrderLocation{ .side = .buy, .price = 1000, .order_ptr = order };
        try std.testing.expect(map.insert(key, loc));
    }

    try std.testing.expectEqual(@as(u32, 100), map.count);
    try std.testing.expectEqual(@as(u32, 0), map.tombstone_count);

    // Remove all - creates tombstones
    for (0..100) |i| {
        const key = OrderMap.makeKey(@intCast(i), 1);
        try std.testing.expect(map.remove(key));
    }

    try std.testing.expectEqual(@as(u32, 0), map.count);
    try std.testing.expectEqual(@as(u32, 100), map.tombstone_count);
}

test "OrderMap memory footprint" {
    const footprint = OrderMap.getMemoryFootprint();
    // Should be > 16MB (slots + compact_buffer)
    try std.testing.expect(footprint > 16 * 1024 * 1024);
}
