const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("zts v0.1.0 - Zig TypeScript Transpiler\n", .{});
}

test "basic" {
    try std.testing.expect(true);
}

const lib = @import("zts_lib");
