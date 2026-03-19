const std = @import("std");
const lib = @import("zts_lib");
const Scanner = lib.lexer.Scanner;
const Parser = lib.parser.Parser;
const Transformer = lib.transformer.Transformer;
const Codegen = lib.codegen.Codegen;
const runner = lib.test262.runner;

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // CLI 인자 파싱
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    // 옵션 파싱
    var input_file: ?[]const u8 = null;
    var output_file: ?[]const u8 = null;
    var minify = false;
    var module_format: lib.codegen.codegen.ModuleFormat = .esm;
    var drop_console = false;
    var drop_debugger = false;
    var sourcemap = false;
    var is_test262 = false;
    var is_tokenize = false;
    var test262_dir: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--test262")) {
            is_test262 = true;
            if (i + 1 < args.len) {
                i += 1;
                test262_dir = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--tokenize")) {
            is_tokenize = true;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--out-file")) {
            if (i + 1 < args.len) {
                i += 1;
                output_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--minify")) {
            minify = true;
        } else if (std.mem.eql(u8, arg, "--format=cjs")) {
            module_format = .cjs;
        } else if (std.mem.eql(u8, arg, "--format=esm")) {
            module_format = .esm;
        } else if (std.mem.eql(u8, arg, "--drop=console")) {
            drop_console = true;
        } else if (std.mem.eql(u8, arg, "--drop=debugger")) {
            drop_debugger = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            sourcemap = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return;
        } else if (arg[0] != '-') {
            input_file = arg;
        } else {
            try stderr.print("zts: unknown option: {s}\n", .{arg});
            return;
        }
    }

    // --test262
    if (is_test262) {
        const dir_path = test262_dir orelse {
            try stderr.print("Error: --test262 requires a directory path\n", .{});
            return;
        };
        const abs_path = try std.fs.cwd().realpathAlloc(allocator, dir_path);
        defer allocator.free(abs_path);
        try stdout.print("Running Test262: {s}\n", .{abs_path});
        const summary = try runner.runDirectory(allocator, abs_path);
        try summary.print(stdout);
        return;
    }

    // --tokenize
    if (is_tokenize) {
        const file_path = input_file orelse {
            try stderr.print("Error: --tokenize requires a file path\n", .{});
            return;
        };
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

    // 트랜스파일
    const file_path = input_file orelse {
        try printUsage(stdout);
        return;
    };

    const source = std.fs.cwd().readFileAlloc(allocator, file_path, 100 * 1024 * 1024) catch |err| {
        try stderr.print("zts: cannot read '{s}': {}\n", .{ file_path, err });
        return;
    };
    defer allocator.free(source);

    // 파싱
    var scanner = Scanner.init(allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(allocator, &scanner);
    defer parser.deinit();
    _ = parser.parse() catch |err| {
        try stderr.print("zts: parse error: {}\n", .{err});
        return;
    };

    // 에러 출력
    if (parser.errors.items.len > 0) {
        for (parser.errors.items) |parse_err| {
            const lc = scanner.getLineColumn(parse_err.span.start);
            try stderr.print("{s}:{d}:{d}: error: {s}\n", .{
                file_path,
                lc.line + 1,
                lc.column + 1,
                parse_err.message,
            });
        }
    }

    // 변환
    var transformer = Transformer.init(allocator, &parser.ast, .{
        .drop_console = drop_console,
        .drop_debugger = drop_debugger,
    });
    const root = transformer.transform() catch |err| {
        try stderr.print("zts: transform error: {}\n", .{err});
        return;
    };
    transformer.scratch.deinit();
    defer transformer.new_ast.deinit();

    // 코드 생성
    var cg = Codegen.initWithOptions(allocator, &transformer.new_ast, .{
        .module_format = module_format,
        .minify = minify,
        .sourcemap = sourcemap,
    });
    if (sourcemap) {
        cg.addSourceFile(file_path) catch {};
    }
    defer cg.deinit();
    const output = cg.generate(root) catch |err| {
        try stderr.print("zts: codegen error: {}\n", .{err});
        return;
    };

    // 출력
    if (output_file) |out_path| {
        std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = output,
        }) catch |err| {
            try stderr.print("zts: cannot write '{s}': {}\n", .{ out_path, err });
            return;
        };

        // 소스맵 파일 출력 (.js.map)
        if (sourcemap) {
            if (cg.generateSourceMap(out_path) catch null) |sm_json| {
                const map_path = try std.fmt.allocPrint(allocator, "{s}.map", .{out_path});
                defer allocator.free(map_path);
                std.fs.cwd().writeFile(.{
                    .sub_path = map_path,
                    .data = sm_json,
                }) catch |err| {
                    try stderr.print("zts: cannot write '{s}': {}\n", .{ map_path, err });
                };
            }
        }
    } else {
        try stdout.writeAll(output);
        // stdout에 소스맵은 inline으로 출력하지 않음 (별도 옵션 필요)
    }
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\zts v0.1.0 - Zig TypeScript Transpiler
        \\
        \\Usage:
        \\  zts <file.ts>                Transpile to stdout
        \\  zts <file.ts> -o <out.js>    Transpile to file
        \\
        \\Options:
        \\  -o, --out-file <path>        Output file path
        \\  --minify                     Minify output
        \\  --format=esm|cjs             Module format (default: esm)
        \\  --drop=console               Remove console.* calls
        \\  --drop=debugger              Remove debugger statements
        \\  --sourcemap                  Generate source map (.js.map)
        \\  --tokenize                   Print tokens instead of transpiling
        \\  --test262 <dir>              Run Test262 tests
        \\  -h, --help                   Show this help
        \\
    , .{});
}

test "basic" {
    try std.testing.expect(true);
}
