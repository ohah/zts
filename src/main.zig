const std = @import("std");
const lib = @import("zts_lib");
const Scanner = lib.lexer.Scanner;
const runner = lib.test262.runner;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI 인자 파싱
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try stdout.print("zts v0.1.0 - Zig TypeScript Transpiler\n\n", .{});
        try stdout.print("Usage:\n", .{});
        try stdout.print("  zts <file.ts>              Transpile a file\n", .{});
        try stdout.print("  zts --test262 <directory>   Run Test262 tests\n", .{});
        try stdout.print("  zts --tokenize <file>       Tokenize and print tokens\n", .{});
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--test262")) {
        if (args.len < 3) {
            try stdout.print("Error: --test262 requires a directory path\n", .{});
            return;
        }
        const dir_path = args[2];

        const abs_path = try std.fs.cwd().realpathAlloc(allocator, dir_path);
        defer allocator.free(abs_path);

        try stdout.print("Running Test262: {s}\n", .{abs_path});
        const summary = try runner.runDirectory(allocator, abs_path);
        try summary.print(stdout);
        return;
    }

    if (std.mem.eql(u8, command, "--tokenize")) {
        if (args.len < 3) {
            try stdout.print("Error: --tokenize requires a file path\n", .{});
            return;
        }
        const file_path = args[2];
        const source = try std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024);
        defer allocator.free(source);

        var scanner = Scanner.init(allocator, source);
        defer scanner.deinit();

        while (true) {
            scanner.next();
            const lc = scanner.getLineColumn(scanner.token.span.start);
            try stdout.print("{d}:{d}\t{s}\t\"{s}\"\n", .{
                lc.line + 1,
                lc.column + 1,
                scanner.token.kind.symbol(),
                scanner.tokenText(),
            });
            if (scanner.token.kind == .eof) break;
        }
        return;
    }

    try stdout.print("zts: transpile not yet implemented. Use --tokenize or --test262\n", .{});
}

test "basic" {
    try std.testing.expect(true);
}
