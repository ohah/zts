const std = @import("std");
const testing = std.testing;

pub const token = @import("token.zig");

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add" {
    try testing.expectEqual(@as(i32, 150), add(100, 50));
}

test {
    // token.zig 내의 모든 테스트를 포함
    _ = token;
}
