const std = @import("std");

pub const BitMapError = error{OutOfBounds};

pub fn StaticBitMap(comptime n_bits: usize) type {
    return struct {
        core: BitMapCore([n_bits]u1),

        const Self = @This();
        pub fn init() Self {
            return .{ .core = .{ .bits = .{0} ** n_bits } };
        }

        pub fn set(self: *Self, index: usize) BitMapError!void {
            return self.core.set(index);
        }

        pub fn clear(self: *Self, index: usize) BitMapError!void {
            return self.core.clear(index);
        }

        pub fn isSet(self: *Self, index: usize) bool {
            return self.core.isSet(index);
        }

        pub fn clearAll(self: *Self) void {
            self.core.clearAll();
        }

        pub fn setAll(self: *Self) void {
            self.core.setAll();
        }

        pub fn toggle(self: *Self, index: usize) BitMapError!void {
            return self.core.toggle(index);
        }

        pub fn count(self: *const Self) usize {
            return self.core.count();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.core.isEmpty();
        }
    };
}

pub const DynamicBitMap = struct {
    const Self = @This();
    core: BitMapCore([]u1),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
        const bits = try allocator.alloc(u1, cap);
        @memset(bits, 0);

        return .{
            .core = .{ .bits = bits },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.core.bits);
    }

    // Delegate to core operations
    pub fn set(self: *Self, index: usize) BitMapError!void {
        return self.core.set(index);
    }

    pub fn clear(self: *Self, index: usize) BitMapError!void {
        return self.core.clear(index);
    }

    pub fn isSet(self: *const Self, index: usize) bool {
        return self.core.isSet(index);
    }

    pub fn clearAll(self: *Self) void {
        self.core.clearAll();
    }

    pub fn setAll(self: *Self) void {
        self.core.setAll();
    }

    pub fn toggle(self: *Self, index: usize) BitMapError!void {
        return self.core.toggle(index);
    }

    pub fn count(self: *const Self) usize {
        return self.core.count();
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.core.isEmpty();
    }

    pub fn resize(self: *Self, new_capacity: usize) !void {
        const new_bits = try self.allocator.alloc(u1, new_capacity);
        const copy_len = @min(self.core.bits.len, new_capacity);
        @memcpy(new_bits[0..copy_len], self.core.bits[0..copy_len]);
        if (new_capacity > self.core.bits.len) {
            @memset(new_bits[self.core.bits.len..], 0);
        }
        self.allocator.free(self.core.bits);
        self.core.bits = new_bits;
    }

    pub fn capacity(self: *const Self) usize {
        return self.core.bits.len;
    }
};

fn BitMapCore(comptime StorageType: type) type {
    return struct {
        const Self = @This();
        bits: StorageType,

        pub inline fn set(self: *Self, index: usize) BitMapError!void {
            if (index >= self.bits.len) return BitMapError.OutOfBounds;
            self.bits[index] = 1;
        }

        pub inline fn clear(self: *Self, index: usize) BitMapError!void {
            if (index >= self.bits.len) return BitMapError.OutOfBounds;
            self.bits[index] = 0;
        }

        pub inline fn isSet(self: *const Self, index: usize) bool {
            if (index >= self.bits.len) return false;
            return self.bits[index] == 1;
        }

        pub inline fn clearAll(self: *Self) void {
            if (StorageType == []u1) {
                @memset(self.bits, 0);
                return;
            }
            @memset(&self.bits, 0);
        }

        pub fn setAll(self: *Self) void {
            if (StorageType == []u1) {
                @memset(self.bits, 1);
                return;
            }

            @memset(&self.bits, 1);
        }

        pub inline fn toggle(self: *Self, index: usize) BitMapError!void {
            if (index >= self.bits.len) return BitMapError.OutOfBounds;
            self.bits[index] = if (self.bits[index] == 0) 1 else 0;
        }

        pub inline fn count(self: *const Self) usize {
            var total: usize = 0;
            for (self.bits) |bit| {
                if (bit == 1) total += 1;
            }
            return total;
        }

        pub inline fn isEmpty(self: *const Self) bool {
            for (self.bits) |bit| {
                if (bit == 1) return false;
            }
            return true;
        }
    };
}

test "set and isSet" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try static_bm.set(10);
    try dynamic_bm.set(10);

    try std.testing.expect(static_bm.isSet(10) == true);
    try std.testing.expect(dynamic_bm.isSet(10) == true);

    try std.testing.expect(static_bm.isSet(4) == false);
    try std.testing.expect(dynamic_bm.isSet(4) == false);
}

test "clear bit" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try static_bm.set(5);
    try dynamic_bm.set(5);

    try std.testing.expect(static_bm.isSet(5) == true);
    try std.testing.expect(dynamic_bm.isSet(5) == true);

    try static_bm.clear(5);
    try dynamic_bm.clear(5);

    try std.testing.expect(static_bm.isSet(5) == false);
    try std.testing.expect(dynamic_bm.isSet(5) == false);
}

test "clearAll" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    static_bm.setAll();
    dynamic_bm.setAll();

    var i: usize = 0;
    while (i < static_bm.count()) : (i += 1) {
        try std.testing.expect(static_bm.isSet(i) == true);
        try std.testing.expect(dynamic_bm.isSet(i) == true);
    }

    static_bm.clearAll();
    dynamic_bm.clearAll();

    i = 0;
    while (i < static_bm.count()) : (i += 1) {
        try std.testing.expect(static_bm.isSet(i) == false);
        try std.testing.expect(dynamic_bm.isSet(i) == false);
    }
}

test "setAll" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    var i: usize = 0;
    while (i < static_bm.count()) : (i += 1) {
        try std.testing.expect(static_bm.isSet(i) == false);
        try std.testing.expect(dynamic_bm.isSet(i) == false);
    }

    static_bm.setAll();
    dynamic_bm.setAll();

    i = 0;
    while (i < static_bm.count()) : (i += 1) {
        try std.testing.expect(static_bm.isSet(i) == true);
        try std.testing.expect(dynamic_bm.isSet(i) == true);
    }
}

test "set out-of-bounds" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try std.testing.expectError(BitMapError.OutOfBounds, static_bm.set(400));
    try std.testing.expectError(BitMapError.OutOfBounds, dynamic_bm.set(400));
}

test "clear out-of-bounds" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try std.testing.expectError(BitMapError.OutOfBounds, static_bm.clear(400));
    try std.testing.expectError(BitMapError.OutOfBounds, dynamic_bm.clear(400));
}

test "multiple operations" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    var i: usize = 0;
    while (i < static_bm.count()) : (i += 1) {
        if (i % 2 == 0) {
            try static_bm.set(i);
            try dynamic_bm.set(i);
        }
    }

    i = 0;
    while (i < static_bm.count()) : (i += 1) {
        if (i % 2 == 0) {
            try std.testing.expect(static_bm.isSet(i) == true);
            try std.testing.expect(dynamic_bm.isSet(i) == true);
        } else {
            try std.testing.expect(static_bm.isSet(i) == false);
            try std.testing.expect(dynamic_bm.isSet(i) == false);
        }
    }

    i = 0;
    while (i < static_bm.count()) : (i += 1) {
        if (i % 2 == 0) {
            try static_bm.clear(i);
            try dynamic_bm.clear(i);
        }
    }

    i = 0;
    while (i < static_bm.count()) : (i += 1) {
        try std.testing.expect(static_bm.isSet(i) == false);
        try std.testing.expect(dynamic_bm.isSet(i) == false);
    }
}

test "set same bit twice" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try static_bm.set(7);
    try dynamic_bm.set(7);

    try std.testing.expect(static_bm.isSet(7) == true);
    try std.testing.expect(dynamic_bm.isSet(7) == true);

    try static_bm.set(7);
    try dynamic_bm.set(7);

    try std.testing.expect(static_bm.isSet(7) == true);
    try std.testing.expect(dynamic_bm.isSet(7) == true);
}

test "set, clear, and re-set bit" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try static_bm.set(3);
    try dynamic_bm.set(3);

    try std.testing.expect(static_bm.isSet(3) == true);
    try std.testing.expect(dynamic_bm.isSet(3) == true);

    try static_bm.clear(3);
    try dynamic_bm.clear(3);

    try std.testing.expect(static_bm.isSet(3) == false);
    try std.testing.expect(dynamic_bm.isSet(3) == false);

    try static_bm.set(3);
    try dynamic_bm.set(3);

    try std.testing.expect(static_bm.isSet(3) == true);
    try std.testing.expect(dynamic_bm.isSet(3) == true);
}

test "clear already clear bit" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try std.testing.expect(static_bm.isSet(5) == false);
    try std.testing.expect(dynamic_bm.isSet(5) == false);

    try static_bm.clear(5);
    try dynamic_bm.clear(5);

    try std.testing.expect(static_bm.isSet(5) == false);
    try std.testing.expect(dynamic_bm.isSet(5) == false);
}

test "toggle bits" {
    var static_bm = StaticBitMap(256).init();
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 256);
    defer dynamic_bm.deinit();

    try std.testing.expect(static_bm.isSet(10) == false);
    try std.testing.expect(dynamic_bm.isSet(10) == false);

    try static_bm.toggle(10);
    try dynamic_bm.toggle(10);

    try std.testing.expect(static_bm.isSet(10) == true);
    try std.testing.expect(dynamic_bm.isSet(10) == true);

    try static_bm.toggle(10);
    try dynamic_bm.toggle(10);

    try std.testing.expect(static_bm.isSet(10) == false);
    try std.testing.expect(dynamic_bm.isSet(10) == false);
}

test "resize dynamic bitmap" {
    var dynamic_bm = try DynamicBitMap.init(std.testing.allocator, 10);
    defer dynamic_bm.deinit();

    try std.testing.expect(dynamic_bm.capacity() == 10);

    try dynamic_bm.set(2);
    try dynamic_bm.set(9);
    try dynamic_bm.resize(20);
    try std.testing.expect(dynamic_bm.capacity() == 20);

    try std.testing.expect(dynamic_bm.isSet(2) == true);
    try std.testing.expect(dynamic_bm.isSet(9) == true);

    try std.testing.expect(dynamic_bm.isSet(15) == false);
    try std.testing.expect(dynamic_bm.isSet(19) == false);

    try dynamic_bm.resize(5);
    try std.testing.expect(dynamic_bm.capacity() == 5);
    try std.testing.expect(dynamic_bm.isSet(9) == false);
}
