//! Order structure - 64-byte cache-line aligned.
//!
//! Design decisions (from Power of Ten + HFT principles):
//! - Aligned to 64-byte cache line to prevent false sharing
//! - No symbol field - order book is single-symbol
//! - Hot fields (accessed during matching) packed first
//! - Uses RDTSCP timestamp for time priority on x86_64 (serializing)
//!
//! Linked list rationale:
//! We use intrusive prev/next pointers despite "avoid lists in hot path"
//! because at each price level, orders are FIFO. Linked lists give O(1)
//! insert at tail and O(1) remove at known position - both critical for
//! matching. The alternative (array + compaction) has worse cache behavior
//! for removals from the middle.

const std = @import("std");
const builtin = @import("builtin");
const msg = @import("../protocol/message_types.zig");

// ============================================================================
// Platform Detection
// ============================================================================

/// We only support x86_64 Linux for production - other platforms may work
/// but haven't been validated for latency characteristics.
/// On non-x86_64-linux platforms, timestamps use std.time which may syscall.
const SUPPORTED_PLATFORM = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

// ============================================================================
// Constants
// ============================================================================

/// Cache line size on modern x86_64 processors
pub const CACHE_LINE_SIZE = 64;

/// Order alignment - one cache line to prevent false sharing
pub const ORDER_ALIGNMENT = CACHE_LINE_SIZE;

/// Maximum order quantity. Chosen because:
/// - Fits comfortably in u32 with room for arithmetic without overflow
/// - Exceeds any real exchange limit (~10M shares typically)
/// - Prevents overflow in quantity × price calculations (u32 × u32 fits in u64)
/// - Round number for easy debugging
pub const MAX_ORDER_QUANTITY: u32 = 1_000_000_000;

/// Minimum valid timestamp (ensures we never have zero timestamps)
pub const MIN_VALID_TIMESTAMP: u64 = 1;

// ============================================================================
// Timestamp Implementation
// ============================================================================

/// Get current timestamp using RDTSCP on x86_64, fallback elsewhere.
///
/// Why RDTSCP (not RDTSC):
/// RDTSC can be reordered by out-of-order execution, potentially causing
/// FIFO violations where two orders submitted in sequence receive inverted
/// timestamps. RDTSCP is a serializing instruction that guarantees all prior
/// instructions complete before reading the TSC.
///
/// RDTSCP characteristics:
/// - ~25-35 cycles on modern CPUs (serializing adds ~5 cycles over RDTSC)
/// - Monotonic within a core
/// - No syscall overhead
/// - Clobbers ECX with processor ID (unused but must be declared)
///
/// For strict FIFO ordering within a single-threaded matching engine,
/// RDTSCP provides the necessary monotonicity guarantees.
///
/// WARNING: On non-x86_64-linux platforms, this uses std.time.nanoTimestamp()
/// which may syscall and add microseconds of latency. This is acceptable for
/// development/testing but NOT for production latency-sensitive deployments.
pub inline fn getCurrentTimestamp() u64 {
    if (comptime SUPPORTED_PLATFORM) {
        // RDTSCP: Read Time Stamp Counter and Processor ID (serializing)
        // Guarantees all prior instructions complete before reading TSC,
        // preventing FIFO violations from out-of-order execution.
        var lo: u32 = undefined;
        var hi: u32 = undefined;
        asm volatile ("rdtscp"
            : [lo] "={eax}" (lo),
              [hi] "={edx}" (hi),
            :
            : "ecx", "memory", // ECX clobbered with processor ID; memory barrier
        );
        return (@as(u64, hi) << 32) | lo;
    } else {
        // Fallback for development/testing on other platforms
        // WARNING: This may syscall and add microseconds of latency
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            // Only log once to avoid spam
            const logged = struct {
                var value: bool = false;
            };
            if (!logged.value) {
                logged.value = true;
                std.log.warn("Using fallback timestamp (not x86_64 Linux) - not suitable for production", .{});
            }
        }
        const ts = std.time.nanoTimestamp();
        std.debug.assert(ts >= 0);
        return @intCast(@as(u128, @intCast(ts)));
    }
}

// ============================================================================
// Order Structure
// ============================================================================

/// Order structure - exactly 64 bytes (one cache line).
///
/// Memory layout (verified at comptime):
/// ```
///   Bytes 0-19:  Hot path fields (accessed during matching)
///   Bytes 20-31: Metadata
///   Bytes 32-39: Timestamp
///   Bytes 40-55: Linked list pointers
///   Bytes 56-63: Reserved padding
/// ```
///
/// Field ordering rationale:
/// - user_id, user_order_id, price, quantity, remaining_qty are accessed
///   on every match check - keeping them in first cache line fetch
/// - Linked list pointers are only touched during insert/remove
/// - Padding ensures the struct is exactly one cache line
pub const Order = extern struct {
    // === HOT PATH FIELDS === (bytes 0-19, accessed every match check)
    user_id: u32, // 0-3:   Owner identification
    user_order_id: u32, // 4-7:   Client's order reference
    price: u32, // 8-11:  Price in ticks (0 = market order)
    quantity: u32, // 12-15: Original quantity (immutable after init)
    remaining_qty: u32, // 16-19: Remaining unfilled quantity

    // === METADATA === (bytes 20-31)
    side: msg.Side, // 20:    Buy or Sell
    order_type: msg.OrderType, // 21:    Market or Limit
    _pad1: [2]u8 = .{ 0, 0 }, // 22-23: Explicit zero padding
    client_id: u32, // 24-27: TCP client ID (0 = UDP origin)
    _pad2: u32 = 0, // 28-31: Align timestamp to 8-byte boundary

    // === TIME PRIORITY === (bytes 32-39)
    timestamp: u64, // 32-39: RDTSCP timestamp for FIFO ordering

    // === LINKED LIST POINTERS === (bytes 40-55)
    /// Next order at same price level (toward tail, newer orders)
    next: ?*Order, // 40-47
    /// Previous order at same price level (toward head, older orders)
    prev: ?*Order, // 48-55

    // === RESERVED === (bytes 56-63)
    /// Reserved for future use (e.g., order flags, sequence number)
    _reserved: u64 = 0, // 56-63

    const Self = @This();

    // ========================================================================
    // Compile-time Layout Verification
    // ========================================================================
    comptime {
        // Size must be exactly one cache line
        std.debug.assert(@sizeOf(Self) == CACHE_LINE_SIZE);
        std.debug.assert(@alignOf(Self) >= 8); // Minimum for pointer alignment

        // Verify hot path fields are in first 20 bytes
        std.debug.assert(@offsetOf(Self, "user_id") == 0);
        std.debug.assert(@offsetOf(Self, "user_order_id") == 4);
        std.debug.assert(@offsetOf(Self, "price") == 8);
        std.debug.assert(@offsetOf(Self, "quantity") == 12);
        std.debug.assert(@offsetOf(Self, "remaining_qty") == 16);

        // Verify metadata layout
        std.debug.assert(@offsetOf(Self, "side") == 20);
        std.debug.assert(@offsetOf(Self, "order_type") == 21);
        std.debug.assert(@offsetOf(Self, "client_id") == 24);

        // Verify timestamp is 8-byte aligned for atomic access
        std.debug.assert(@offsetOf(Self, "timestamp") == 32);
        std.debug.assert(@offsetOf(Self, "timestamp") % 8 == 0);

        // Verify pointer layout
        std.debug.assert(@offsetOf(Self, "next") == 40);
        std.debug.assert(@offsetOf(Self, "prev") == 48);
        std.debug.assert(@offsetOf(Self, "_reserved") == 56);
    }

    // ========================================================================
    // Initialization
    // ========================================================================

    /// Initialize order from new order message.
    ///
    /// Caller must provide timestamp from getCurrentTimestamp().
    /// This separation allows batching timestamp reads.
    ///
    /// Preconditions (enforced by assertions):
    /// - quantity > 0 and <= MAX_ORDER_QUANTITY
    /// - timestamp >= MIN_VALID_TIMESTAMP
    pub fn init(order_msg: *const msg.NewOrderMsg, client_id: u32, ts: u64) Self {
        // Rule 7: Validate all parameters
        std.debug.assert(order_msg.quantity > 0);
        std.debug.assert(order_msg.quantity <= MAX_ORDER_QUANTITY);
        std.debug.assert(ts >= MIN_VALID_TIMESTAMP);

        const order = Self{
            .user_id = order_msg.user_id,
            .user_order_id = order_msg.user_order_id,
            .price = order_msg.price,
            .quantity = order_msg.quantity,
            .remaining_qty = order_msg.quantity,
            .side = order_msg.side,
            .order_type = if (order_msg.price == 0) .market else .limit,
            .client_id = client_id,
            .timestamp = ts,
            .next = null,
            .prev = null,
        };

        // Post-condition: order is valid
        std.debug.assert(order.isValid());
        return order;
    }

    // ========================================================================
    // Invariant Checking
    // ========================================================================

    /// Check all order invariants. Use in debug assertions.
    ///
    /// Invariants:
    /// - remaining_qty <= quantity
    /// - quantity > 0 and <= MAX_ORDER_QUANTITY
    /// - Market orders have price == 0
    /// - Limit orders have price > 0
    /// - timestamp >= MIN_VALID_TIMESTAMP
    pub inline fn isValid(self: *const Self) bool {
        // Remaining can't exceed original
        if (self.remaining_qty > self.quantity) return false;

        // Original quantity must be positive and bounded
        if (self.quantity == 0) return false;
        if (self.quantity > MAX_ORDER_QUANTITY) return false;

        // Market orders have price 0, limit orders have price > 0
        if (self.order_type == .market and self.price != 0) return false;
        if (self.order_type == .limit and self.price == 0) return false;

        // Timestamp must be set
        if (self.timestamp < MIN_VALID_TIMESTAMP) return false;

        return true;
    }

    // ========================================================================
    // Order State Queries
    // ========================================================================

    /// Check if order is fully filled (remaining quantity is zero).
    pub inline fn isFilled(self: *const Self) bool {
        std.debug.assert(self.isValid());
        return self.remaining_qty == 0;
    }

    /// Check if order is still active (has remaining quantity).
    pub inline fn isActive(self: *const Self) bool {
        std.debug.assert(self.isValid());
        return self.remaining_qty > 0;
    }

    /// Check if this order is currently linked into a price level list.
    pub inline fn isLinked(self: *const Self) bool {
        return self.prev != null or self.next != null;
    }

    // ========================================================================
    // Order Modification
    // ========================================================================

    /// Fill order by quantity, returns amount actually filled.
    ///
    /// Guarantees:
    /// - Never fills more than remaining
    /// - Never underflows remaining_qty
    /// - Returns exact amount filled (may be less than requested)
    ///
    /// Preconditions:
    /// - qty > 0
    /// - remaining_qty > 0
    pub inline fn fill(self: *Self, qty: u32) u32 {
        // Pre-conditions
        std.debug.assert(qty > 0);
        std.debug.assert(self.remaining_qty > 0);
        std.debug.assert(self.isValid());

        const filled = @min(qty, self.remaining_qty);

        // This subtraction is safe: filled <= remaining_qty by construction
        self.remaining_qty -= filled;

        // Post-conditions
        std.debug.assert(self.remaining_qty <= self.quantity);
        std.debug.assert(filled > 0);
        std.debug.assert(filled <= qty);

        return filled;
    }

    // ========================================================================
    // Price Crossing
    // ========================================================================

    /// Check if this order's price crosses (can trade with) the given price.
    ///
    /// Crossing means:
    /// - For buys:  our bid >= their ask (we're willing to pay enough)
    /// - For sells: our ask <= their bid (we're willing to sell cheap enough)
    /// - Market orders (price=0) cross any price
    ///
    /// Preconditions:
    /// - Order must be active
    /// - resting_price > 0 (resting orders are always limit orders)
    pub inline fn pricesCross(self: *const Self, resting_price: u32) bool {
        // Pre-conditions
        std.debug.assert(self.isActive());
        std.debug.assert(resting_price > 0); // Resting orders must have real prices

        // Market orders always cross
        if (self.price == 0) {
            std.debug.assert(self.order_type == .market);
            return true;
        }

        return switch (self.side) {
            .buy => self.price >= resting_price,
            .sell => self.price <= resting_price,
        };
    }

    // ========================================================================
    // Linked List Operations
    // ========================================================================

    /// Unlink this order from its doubly-linked list.
    ///
    /// Updates neighbors' pointers to bypass this order, then clears
    /// this order's own prev/next pointers.
    ///
    /// Note: This does NOT update PriceLevel head/tail pointers.
    /// Use PriceLevel.removeOrder() for complete removal from a price level.
    pub inline fn unlink(self: *Self) void {
        if (self.prev) |prev| {
            prev.next = self.next;
        }
        if (self.next) |next| {
            next.prev = self.prev;
        }

        self.prev = null;
        self.next = null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Order size and alignment" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Order));
    try std.testing.expect(@alignOf(Order) >= 8);
}

test "Order field offsets" {
    // Hot path fields in first 20 bytes
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Order, "user_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Order, "price"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Order, "remaining_qty"));

    // Timestamp 8-byte aligned
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Order, "timestamp"));
}

test "Order init and validation" {
    const new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 100,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };

    const order = Order.init(&new_order, 42, 12345);

    try std.testing.expectEqual(@as(u32, 1), order.user_id);
    try std.testing.expectEqual(@as(u32, 100), order.user_order_id);
    try std.testing.expectEqual(@as(u32, 5000), order.price);
    try std.testing.expectEqual(@as(u32, 100), order.quantity);
    try std.testing.expectEqual(@as(u32, 100), order.remaining_qty);
    try std.testing.expectEqual(@as(u32, 42), order.client_id);
    try std.testing.expectEqual(msg.OrderType.limit, order.order_type);
    try std.testing.expect(order.isValid());
    try std.testing.expect(order.isActive());
    try std.testing.expect(!order.isFilled());
    try std.testing.expect(!order.isLinked());
}

test "Order fill mechanics" {
    const new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 100,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };

    var order = Order.init(&new_order, 0, 12345);

    // Partial fill
    const filled1 = order.fill(30);
    try std.testing.expectEqual(@as(u32, 30), filled1);
    try std.testing.expectEqual(@as(u32, 70), order.remaining_qty);
    try std.testing.expect(order.isValid());
    try std.testing.expect(!order.isFilled());

    // Another partial fill
    const filled2 = order.fill(50);
    try std.testing.expectEqual(@as(u32, 50), filled2);
    try std.testing.expectEqual(@as(u32, 20), order.remaining_qty);

    // Final fill
    const filled3 = order.fill(20);
    try std.testing.expectEqual(@as(u32, 20), filled3);
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "Order fill clamping" {
    const new_order = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 100,
        .price = 5000,
        .quantity = 50,
        .side = .buy,
        .symbol = msg.makeSymbol("IBM"),
    };

    var order = Order.init(&new_order, 0, 12345);

    // Try to fill more than available
    const filled = order.fill(100);
    try std.testing.expectEqual(@as(u32, 50), filled); // Clamped
    try std.testing.expectEqual(@as(u32, 0), order.remaining_qty);
    try std.testing.expect(order.isFilled());
}

test "Order price crossing - limit orders" {
    const buy_order_msg = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 100, // Willing to pay up to 100
        .quantity = 10,
        .side = .buy,
        .symbol = msg.makeSymbol("TEST"),
    };
    const buy = Order.init(&buy_order_msg, 0, 1);

    // Buy at 100 crosses sell at 100 or below
    try std.testing.expect(buy.pricesCross(100)); // Equal - crosses
    try std.testing.expect(buy.pricesCross(99)); // Below - crosses
    try std.testing.expect(!buy.pricesCross(101)); // Above - no cross

    const sell_order_msg = msg.NewOrderMsg{
        .user_id = 2,
        .user_order_id = 2,
        .price = 100, // Willing to sell at 100 or above
        .quantity = 10,
        .side = .sell,
        .symbol = msg.makeSymbol("TEST"),
    };
    const sell = Order.init(&sell_order_msg, 0, 2);

    // Sell at 100 crosses buy at 100 or above
    try std.testing.expect(sell.pricesCross(100)); // Equal - crosses
    try std.testing.expect(sell.pricesCross(101)); // Above - crosses
    try std.testing.expect(!sell.pricesCross(99)); // Below - no cross
}

test "Order price crossing - market orders" {
    const market_buy_msg = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 0, // Market order
        .quantity = 10,
        .side = .buy,
        .symbol = msg.makeSymbol("TEST"),
    };
    const market = Order.init(&market_buy_msg, 0, 1);

    try std.testing.expectEqual(msg.OrderType.market, market.order_type);

    // Market orders cross any price
    try std.testing.expect(market.pricesCross(1));
    try std.testing.expect(market.pricesCross(1000));
    try std.testing.expect(market.pricesCross(999999));
}

test "Order linking and unlinking" {
    const msg1 = msg.NewOrderMsg{
        .user_id = 1,
        .user_order_id = 1,
        .price = 100,
        .quantity = 10,
        .side = .buy,
        .symbol = msg.makeSymbol("TEST"),
    };
    const msg2 = msg.NewOrderMsg{
        .user_id = 2,
        .user_order_id = 2,
        .price = 100,
        .quantity = 10,
        .side = .buy,
        .symbol = msg.makeSymbol("TEST"),
    };
    const msg3 = msg.NewOrderMsg{
        .user_id = 3,
        .user_order_id = 3,
        .price = 100,
        .quantity = 10,
        .side = .buy,
        .symbol = msg.makeSymbol("TEST"),
    };

    var order1 = Order.init(&msg1, 0, 1);
    var order2 = Order.init(&msg2, 0, 2);
    var order3 = Order.init(&msg3, 0, 3);

    // Initially not linked
    try std.testing.expect(!order1.isLinked());
    try std.testing.expect(!order2.isLinked());
    try std.testing.expect(!order3.isLinked());

    // Link them: order1 <-> order2 <-> order3
    order1.next = &order2;
    order2.prev = &order1;
    order2.next = &order3;
    order3.prev = &order2;

    try std.testing.expect(order1.isLinked());
    try std.testing.expect(order2.isLinked());
    try std.testing.expect(order3.isLinked());

    // Unlink middle order
    order2.unlink();

    try std.testing.expect(!order2.isLinked());
    try std.testing.expect(order2.prev == null);
    try std.testing.expect(order2.next == null);

    // Neighbors should be connected
    try std.testing.expectEqual(&order3, order1.next);
    try std.testing.expectEqual(&order1, order3.prev);

    // First and last still linked
    try std.testing.expect(order1.isLinked());
    try std.testing.expect(order3.isLinked());
}

test "Timestamp monotonicity" {
    const t1 = getCurrentTimestamp();
    const t2 = getCurrentTimestamp();
    const t3 = getCurrentTimestamp();

    // Timestamps should be monotonically increasing (or equal for very fast calls)
    try std.testing.expect(t2 >= t1);
    try std.testing.expect(t3 >= t2);
}

test "Timestamp non-zero" {
    // Ensure we never get a zero timestamp (which would fail isValid)
    const t = getCurrentTimestamp();
    try std.testing.expect(t >= MIN_VALID_TIMESTAMP);
}

test "Market order initialization" {
    const market_order = msg.NewOrderMsg{
        .user_id = 5,
        .user_order_id = 42,
        .price = 0, // Market order indicator
        .quantity = 500,
        .side = .sell,
        .symbol = msg.makeSymbol("AAPL"),
    };

    const order = Order.init(&market_order, 100, 999999);

    try std.testing.expectEqual(@as(u32, 0), order.price);
    try std.testing.expectEqual(msg.OrderType.market, order.order_type);
    try std.testing.expect(order.isValid());
}

test "MAX_ORDER_QUANTITY constant" {
    try std.testing.expectEqual(@as(u32, 1_000_000_000), MAX_ORDER_QUANTITY);

    // Verify it fits in u32 with headroom
    try std.testing.expect(MAX_ORDER_QUANTITY < std.math.maxInt(u32));
}
