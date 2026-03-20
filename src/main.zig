const std = @import("std");
const lib = @import("zts_lib");
const Scanner = lib.lexer.Scanner;
const Parser = lib.parser.Parser;
const Diagnostic = lib.diagnostic.Diagnostic;
const SemanticAnalyzer = lib.semantic.SemanticAnalyzer;
const Transformer = lib.transformer.Transformer;
const Codegen = lib.codegen.Codegen;
const TsConfig = lib.config.TsConfig;
const runner = lib.test262.runner;

/// 트랜스파일 옵션을 담는 구조체.
/// CLI에서 파싱한 옵션들을 transpileFile / walkAndTranspile에 전달한다.
const TranspileOptions = struct {
    module_format: lib.codegen.codegen.ModuleFormat = .esm,
    minify: bool = false,
    drop_console: bool = false,
    drop_debugger: bool = false,
    sourcemap: bool = false,
    ascii_only: bool = false,
};

/// 단일 파일을 트랜스파일한다.
/// file_path: 입력 파일 경로, output_path: 출력 파일 경로 (null이면 stdout)
/// source가 null이면 file_path에서 읽고, non-null이면 해당 소스를 사용한다 (stdin 등).
///
/// Arena allocator 패턴:
/// 함수 내부에서 ArenaAllocator를 생성하여 모든 모듈(Scanner, Parser, Analyzer,
/// Transformer, Codegen)이 같은 Arena를 사용한다. 함수가 끝나면 arena.deinit()으로
/// 모든 메모리를 일괄 해제한다.
/// - Scanner의 comments/line_offsets를 Codegen이 마지막에 참조하므로
///   Phase별 Arena 분리는 불가능 → 파일당 Arena 1개가 최적.
/// - source_override(stdin)는 호출자가 관리하는 메모리이므로 Arena와 무관.
/// - cg.generate() 반환값(buf.items)은 Arena 메모리의 slice이므로
///   파일 쓰기/stdout 출력 후에야 arena.deinit()이 실행되어야 한다.
fn transpileFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source_override: ?[]const u8,
    output_path: ?[]const u8,
    options: TranspileOptions,
) !void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    // 파일당 Arena allocator: 모든 내부 할당을 Arena에서 수행하고,
    // 함수 끝에서 일괄 해제한다. backing allocator(GPA)는 debug leak detection용.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit(); // 함수 끝에서 모든 메모리 일괄 해제
    const arena_alloc = arena.allocator();

    // 소스 읽기 — Arena에서 할당하므로 별도 free 불필요
    const source = source_override orelse blk: {
        break :blk std.fs.cwd().readFileAlloc(arena_alloc, file_path, 100 * 1024 * 1024) catch |err| {
            try stderr.print("zts: cannot read '{s}': {}\n", .{ file_path, err });
            return;
        };
    };

    // 파싱 — 모든 모듈이 arena_alloc을 사용하므로 개별 deinit 불필요
    var scanner = try Scanner.init(arena_alloc, source);
    var parser = Parser.init(arena_alloc, &scanner);
    _ = parser.parse() catch |err| {
        try stderr.print("zts: parse error in '{s}': {}\n", .{ file_path, err });
        return;
    };

    // 파서 에러 출력 (코드 프레임, D012)
    if (parser.errors.items.len > 0) {
        for (parser.errors.items) |diag| {
            try printErrorCodeFrame(stderr, source, file_path, &scanner, diag);
        }
        return; // 파서 에러가 있으면 변환하지 않음
    }

    // Semantic analysis (D038): 파서 에러가 없을 때만 실행
    {
        var analyzer = SemanticAnalyzer.init(arena_alloc, &parser.ast);
        analyzer.is_strict_mode = parser.is_strict_mode;
        analyzer.is_module = parser.is_module;
        analyzer.analyze();
        if (analyzer.errors.items.len > 0) {
            for (analyzer.errors.items) |diag| {
                try printErrorCodeFrame(stderr, source, file_path, &scanner, diag);
            }
            return; // semantic 에러가 있으면 변환하지 않음
        }
    }

    // 변환
    var transformer = Transformer.init(arena_alloc, &parser.ast, .{
        .drop_console = options.drop_console,
        .drop_debugger = options.drop_debugger,
    });
    const root = transformer.transform() catch |err| {
        try stderr.print("zts: transform error in '{s}': {}\n", .{ file_path, err });
        return;
    };

    // 코드 생성
    var cg = Codegen.initWithOptions(arena_alloc, &transformer.new_ast, .{
        .module_format = options.module_format,
        .minify = options.minify,
        .sourcemap = options.sourcemap,
        .ascii_only = options.ascii_only,
    });
    cg.comments = scanner.comments.items;
    if (options.sourcemap) {
        cg.addSourceFile(file_path) catch |err| {
            try stderr.print("zts: sourcemap init error in '{s}': {}\n", .{ file_path, err });
        };
        cg.line_offsets = scanner.line_offsets.items;
    }
    const output = cg.generate(root) catch |err| {
        try stderr.print("zts: codegen error in '{s}': {}\n", .{ file_path, err });
        return;
    };

    // 출력 — output은 Arena 메모리의 slice이므로 arena.deinit() 전에 완료해야 함
    if (output_path) |out_path| {
        // 출력 디렉토리가 없으면 생성
        if (std.fs.path.dirname(out_path)) |dir| {
            std.fs.cwd().makePath(dir) catch |err| {
                try stderr.print("zts: cannot create directory '{s}': {}\n", .{ dir, err });
                return;
            };
        }

        std.fs.cwd().writeFile(.{
            .sub_path = out_path,
            .data = output,
        }) catch |err| {
            try stderr.print("zts: cannot write '{s}': {}\n", .{ out_path, err });
            return;
        };

        // 소스맵 파일 출력 (.js.map)
        if (options.sourcemap) {
            if (cg.generateSourceMap(out_path) catch null) |sm_json| {
                const map_path = try std.fmt.allocPrint(arena_alloc, "{s}.map", .{out_path});
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
    }
}

/// 디렉토리를 재귀 순회하며 .ts/.tsx 파일을 찾아 트랜스파일한다.
/// input_dir: 입력 디렉토리 경로, output_dir: 출력 디렉토리 경로
/// .d.ts 파일과 node_modules 디렉토리는 건너뛴다.
fn walkAndTranspile(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    options: TranspileOptions,
) !void {
    const stderr = std.io.getStdErr().writer();
    const stdout = std.io.getStdOut().writer();

    // 입력 디렉토리 열기
    var dir = std.fs.cwd().openDir(input_dir, .{ .iterate = true }) catch |err| {
        try stderr.print("zts: cannot open directory '{s}': {}\n", .{ input_dir, err });
        return;
    };
    defer dir.close();

    // 재귀적으로 파일 순회
    var walker = dir.walk(allocator) catch |err| {
        try stderr.print("zts: cannot walk directory '{s}': {}\n", .{ input_dir, err });
        return;
    };
    defer walker.deinit();

    var file_count: usize = 0;

    while (walker.next() catch |err| {
        try stderr.print("zts: error walking directory: {}\n", .{err});
        return;
    }) |entry| {
        // 디렉토리는 건너뛰되, node_modules는 순회 자체를 차단할 수 없으므로
        // 파일 경로에 node_modules가 포함되면 건너뛴다
        if (entry.kind != .file) continue;

        const path = entry.path; // input_dir 기준 상대 경로

        // node_modules 포함 경로 건너뛰기
        if (std.mem.indexOf(u8, path, "node_modules") != null) continue;

        // .ts 또는 .tsx 파일만 처리
        const is_ts = std.mem.endsWith(u8, path, ".ts");
        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        if (!is_ts and !is_tsx) continue;

        // .d.ts 파일 건너뛰기
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;

        // 입력 파일의 전체 경로 구성
        const input_path = try std.fs.path.join(allocator, &.{ input_dir, path });
        defer allocator.free(input_path);

        // 출력 경로 구성: 확장자를 .js로 변경
        const basename_no_ext = if (is_tsx)
            path[0 .. path.len - 4] // ".tsx" 제거
        else
            path[0 .. path.len - 3]; // ".ts" 제거
        const output_rel = try std.fmt.allocPrint(allocator, "{s}.js", .{basename_no_ext});
        defer allocator.free(output_rel);

        const output_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel });
        defer allocator.free(output_path);

        // 진행 상황 출력
        try stdout.print("{s} → {s}\n", .{ input_path, output_path });

        // 트랜스파일 실행
        try transpileFile(allocator, input_path, null, output_path, options);
        file_count += 1;
    }

    if (file_count == 0) {
        try stderr.print("zts: no .ts/.tsx files found in '{s}'\n", .{input_dir});
    } else {
        try stdout.print("\nDone: {d} file(s) transpiled.\n", .{file_count});
    }
}

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
    var output_dir: ?[]const u8 = null;
    var minify = false;
    var module_format: lib.codegen.codegen.ModuleFormat = .esm;
    var drop_console = false;
    var drop_debugger = false;
    var sourcemap = false;
    var ascii_only = false;
    var watch = false;
    var is_test262 = false;
    var is_tokenize = false;
    var test262_dir: ?[]const u8 = null;
    var project_path: ?[]const u8 = null;

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
        } else if (std.mem.eql(u8, arg, "--outdir")) {
            if (i + 1 < args.len) {
                i += 1;
                output_dir = args[i];
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
        } else if (std.mem.eql(u8, arg, "--ascii-only")) {
            ascii_only = true;
        } else if (std.mem.eql(u8, arg, "--sourcemap")) {
            sourcemap = true;
        } else if (std.mem.eql(u8, arg, "--project") or std.mem.eql(u8, arg, "-p")) {
            if (i + 1 < args.len) {
                i += 1;
                project_path = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            watch = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printUsage(stdout);
            return;
        } else if (arg[0] != '-' or (arg.len == 1 and arg[0] == '-')) {
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
        const summary = try runner.runDirectory(allocator, abs_path, false);
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

        var scanner = try Scanner.init(allocator, source);
        defer scanner.deinit();

        while (true) {
            try scanner.next();
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

    // 입력 경로가 디렉토리인지 확인
    const input_path_str = input_file orelse {
        try printUsage(stdout);
        return;
    };

    // tsconfig.json 로드.
    // 우선순위: --project 경로 > 입력이 디렉토리면 그 디렉토리 > 입력 파일의 부모 디렉토리
    const tsconfig_dir: []const u8 = if (project_path) |pp|
        pp
    else if (!std.mem.eql(u8, input_path_str, "-"))
        // 파일이면 dirname, 디렉토리면 그대로
        std.fs.path.dirname(input_path_str) orelse "."
    else
        ".";

    var tsconfig = TsConfig.load(allocator, tsconfig_dir) catch TsConfig{};
    defer tsconfig.deinit();

    // tsconfig 값을 기본값으로 사용하되, CLI 옵션이 우선한다.
    // CLI에서 명시적으로 설정하지 않은 옵션만 tsconfig에서 가져온다.
    // module_format: tsconfig의 module이 "commonjs"이면 cjs 사용
    if (module_format == .esm) { // CLI에서 --format=cjs를 안 했으면
        if (tsconfig.module) |mod| {
            if (std.ascii.eqlIgnoreCase(mod, "commonjs")) {
                module_format = .cjs;
            }
        }
    }
    // sourcemap: tsconfig에서 true이면 적용 (CLI --sourcemap이 이미 true면 그대로)
    if (!sourcemap and tsconfig.source_map) {
        sourcemap = true;
    }
    // output_dir: tsconfig의 outDir를 기본값으로 사용
    if (output_dir == null) {
        if (tsconfig.out_dir) |od| {
            output_dir = od;
        }
    }

    // 트랜스파일 옵션 구성
    const options = TranspileOptions{
        .module_format = module_format,
        .minify = minify,
        .drop_console = drop_console,
        .drop_debugger = drop_debugger,
        .sourcemap = sourcemap,
        .ascii_only = ascii_only,
    };

    const is_stdin = std.mem.eql(u8, input_path_str, "-");

    if (!is_stdin) {
        // statFile로 디렉토리 여부 판별
        const stat = std.fs.cwd().statFile(input_path_str) catch |err| {
            // statFile이 실패하면 openDir을 시도하여 디렉토리인지 확인
            // (일부 시스템에서 디렉토리에 statFile이 실패할 수 있음)
            var dir = std.fs.cwd().openDir(input_path_str, .{}) catch {
                // 파일도 디렉토리도 아닌 경우
                try stderr.print("zts: cannot access '{s}': {}\n", .{ input_path_str, err });
                return;
            };
            dir.close();
            // 디렉토리 확인됨 — 아래 디렉토리 처리로 이동
            const out_dir = output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                return;
            };
            try walkAndTranspile(allocator, input_path_str, out_dir, options);
            if (watch) {
                try watchDirectory(allocator, input_path_str, out_dir, options, stderr);
            }
            return;
        };

        if (stat.kind == .directory) {
            const out_dir = output_dir orelse {
                try stderr.print("zts: --outdir is required when input is a directory\n", .{});
                return;
            };
            try walkAndTranspile(allocator, input_path_str, out_dir, options);
            if (watch) {
                try watchDirectory(allocator, input_path_str, out_dir, options, stderr);
            }
            return;
        }
    }

    // 단일 파일 트랜스파일 (기존 로직)
    const file_path = if (is_stdin) "<stdin>" else input_path_str;

    if (is_stdin) {
        const source = std.io.getStdIn().readToEndAlloc(allocator, 100 * 1024 * 1024) catch |err| {
            try stderr.print("zts: cannot read stdin: {}\n", .{err});
            return;
        };
        defer allocator.free(source);
        try transpileFile(allocator, file_path, source, output_file, options);
    } else {
        try transpileFile(allocator, file_path, null, output_file, options);
        if (watch) {
            try watchFile(allocator, file_path, output_file, options, stderr);
        }
    }
}

/// 단일 파일을 폴링 방식으로 감시한다 (D048).
/// 파일의 mtime을 500ms마다 확인하여 변경되면 재트랜스파일한다.
/// Ctrl+C로 종료될 때까지 무한 루프를 돈다.
fn watchFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    output_path: ?[]const u8,
    options: TranspileOptions,
    stderr: anytype,
) !void {
    const stdout = std.io.getStdOut().writer();

    // 초기 mtime 저장
    var last_mtime = getFileMtime(file_path) catch |err| {
        try stderr.print("zts: cannot stat '{s}': {}\n", .{ file_path, err });
        return;
    };

    try stdout.print("[watch] Watching for file changes...\n", .{});

    while (true) {
        std.time.sleep(500 * std.time.ns_per_ms);

        const current_mtime = getFileMtime(file_path) catch continue;

        if (current_mtime != last_mtime) {
            last_mtime = current_mtime;
            try stdout.print("[watch] File changed: {s}\n", .{file_path});
            transpileFile(allocator, file_path, null, output_path, options) catch |err| {
                try stderr.print("zts: watch re-transpile error: {}\n", .{err});
            };
        }
    }
}

/// 디렉토리를 폴링 방식으로 감시한다 (D048).
/// 매 500ms마다 디렉토리를 재순회하여 .ts/.tsx 파일의 mtime을 확인하고,
/// 변경된 파일만 재트랜스파일한다.
fn watchDirectory(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    output_dir: []const u8,
    options: TranspileOptions,
    stderr: anytype,
) !void {
    const stdout = std.io.getStdOut().writer();

    // mtime 맵: 파일 경로(소유) -> mtime
    var mtime_map = std.StringHashMap(i128).init(allocator);
    defer {
        var it = mtime_map.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
        }
        mtime_map.deinit();
    }

    // 초기 mtime 수집
    try collectMtimes(allocator, input_dir, &mtime_map);

    try stdout.print("[watch] Watching for file changes...\n", .{});

    while (true) {
        std.time.sleep(500 * std.time.ns_per_ms);

        // 현재 파일 상태 수집
        var current_mtimes = std.StringHashMap(i128).init(allocator);
        defer {
            var it = current_mtimes.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
            }
            current_mtimes.deinit();
        }

        collectMtimes(allocator, input_dir, &current_mtimes) catch continue;

        // 변경된 파일 찾기
        var it = current_mtimes.iterator();
        while (it.next()) |entry| {
            const path = entry.key_ptr.*;
            const current_mtime = entry.value_ptr.*;

            const old_mtime = mtime_map.get(path);
            if (old_mtime == null or old_mtime.? != current_mtime) {
                try stdout.print("[watch] File changed: {s}\n", .{path});

                // 출력 경로 계산
                // path는 input_dir/relative 형태이므로 input_dir 접두사를 제거
                const rel_path = if (std.mem.startsWith(u8, path, input_dir))
                    path[input_dir.len + 1 ..] // +1 for path separator
                else
                    path;

                const is_tsx = std.mem.endsWith(u8, rel_path, ".tsx");
                const basename_no_ext = if (is_tsx)
                    rel_path[0 .. rel_path.len - 4]
                else
                    rel_path[0 .. rel_path.len - 3];
                const output_rel = try std.fmt.allocPrint(allocator, "{s}.js", .{basename_no_ext});
                defer allocator.free(output_rel);
                const out_path = try std.fs.path.join(allocator, &.{ output_dir, output_rel });
                defer allocator.free(out_path);

                transpileFile(allocator, path, null, out_path, options) catch |err| {
                    try stderr.print("zts: watch re-transpile error: {}\n", .{err});
                };

                // mtime 맵 업데이트 - 키를 복제하여 저장
                const owned_key = try allocator.dupe(u8, path);
                if (mtime_map.fetchPut(owned_key, current_mtime) catch null) |old| {
                    allocator.free(old.key);
                }
            }
        }
    }
}

/// 파일의 mtime(수정 시각)을 i128 나노초 단위로 반환한다.
fn getFileMtime(path: []const u8) !i128 {
    const stat = try std.fs.cwd().statFile(path);
    return stat.mtime;
}

/// 디렉토리를 순회하며 .ts/.tsx 파일의 mtime을 수집한다.
/// mtime_map에 파일 전체 경로(소유) -> mtime을 저장한다.
fn collectMtimes(
    allocator: std.mem.Allocator,
    input_dir: []const u8,
    mtime_map: *std.StringHashMap(i128),
) !void {
    var dir = try std.fs.cwd().openDir(input_dir, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const path = entry.path;
        if (std.mem.indexOf(u8, path, "node_modules") != null) continue;

        const is_ts = std.mem.endsWith(u8, path, ".ts");
        const is_tsx = std.mem.endsWith(u8, path, ".tsx");
        if (!is_ts and !is_tsx) continue;
        if (std.mem.endsWith(u8, path, ".d.ts")) continue;

        // 전체 경로 구성
        const full_path = try std.fs.path.join(allocator, &.{ input_dir, path });

        const mtime = getFileMtime(full_path) catch {
            allocator.free(full_path);
            continue;
        };

        // full_path를 키로 소유권 이전
        mtime_map.put(full_path, mtime) catch {
            allocator.free(full_path);
            continue;
        };
    }
}

/// 에러 코드 프레임 출력 (D012).
/// 형식:
///   file.ts:3:5: error: expected ';'
///     3 | const x =
///       |           ^
fn printErrorCodeFrame(writer: anytype, source: []const u8, file_path: []const u8, scanner: *const Scanner, err: Diagnostic) !void {
    const lc = scanner.getLineColumn(err.span.start);
    const line_num = lc.line + 1;
    const col_num = lc.column + 1;

    // 에러 헤더
    const kind_label: []const u8 = switch (err.kind) {
        .parse => "error",
        .semantic => "error[semantic]",
    };
    if (err.found) |found| {
        try writer.print("{s}:{d}:{d}: {s}: Expected '{s}' but found '{s}'\n", .{ file_path, line_num, col_num, kind_label, err.message, found });
    } else {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{ file_path, line_num, col_num, kind_label, err.message });
    }

    // 해당 줄 텍스트 추출
    const line_start = if (lc.line < scanner.line_offsets.items.len)
        scanner.line_offsets.items[lc.line]
    else
        0;

    var line_end = line_start;
    while (line_end < source.len and source[line_end] != '\n' and source[line_end] != '\r') {
        line_end += 1;
    }
    const line_text = source[line_start..line_end];

    // 줄 번호 너비 계산
    var num_width: usize = 0;
    var n = line_num;
    while (n > 0) : (n /= 10) {
        num_width += 1;
    }

    // 소스 줄 출력: "  3 | const x ="
    try writer.print("  {d} | {s}\n", .{ line_num, line_text });

    // 밑줄 출력: "    |           ^"
    // 줄 번호 자리만큼 공백
    var i: usize = 0;
    while (i < num_width + 2) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll("| ");

    // 열 위치까지 공백
    i = 0;
    while (i < lc.column) : (i += 1) {
        // 원본에서 탭이면 탭으로 맞춤
        if (line_start + i < source.len and source[line_start + i] == '\t') {
            try writer.writeByte('\t');
        } else {
            try writer.writeByte(' ');
        }
    }

    // 밑줄
    const err_len = if (err.span.end > err.span.start)
        @min(err.span.end - err.span.start, line_end - (line_start + lc.column))
    else
        1;
    i = 0;
    while (i < err_len) : (i += 1) {
        try writer.writeByte('^');
    }
    try writer.writeByte('\n');

    // 힌트 출력 (예: "  hint: Try inserting a semicolon here")
    if (err.hint) |hint| {
        try writer.print("  hint: {s}\n", .{hint});
    }

    // 관련 위치 출력 (예: "  --> file.ts:1:10: opening '(' is here")
    if (err.related_span) |rel_span| {
        const rel_lc = scanner.getLineColumn(rel_span.start);
        const rel_line = rel_lc.line + 1;
        const rel_col = rel_lc.column + 1;
        const label = err.related_label orelse "related";
        try writer.print("  --> {s}:{d}:{d}: {s}\n", .{ file_path, rel_line, rel_col, label });
    }
}

fn printUsage(writer: anytype) !void {
    try writer.print(
        \\zts v0.1.0 - Zig TypeScript Transpiler
        \\
        \\Usage:
        \\  zts <file.ts>                Transpile to stdout
        \\  zts <file.ts> -o <out.js>    Transpile to file
        \\  zts <dir/> --outdir <out/>   Transpile directory recursively
        \\  zts - < input.ts             Read from stdin
        \\
        \\Options:
        \\  -o, --out-file <path>        Output file path
        \\  --outdir <path>              Output directory (for directory input)
        \\  --minify                     Minify output
        \\  --format=esm|cjs             Module format (default: esm)
        \\  --drop=console               Remove console.* calls
        \\  --drop=debugger              Remove debugger statements
        \\  --sourcemap                  Generate source map (.js.map)
        \\  --ascii-only                 Escape non-ASCII to \uXXXX
        \\  -w, --watch                  Watch for file changes and re-transpile
        \\  -p, --project <path>         Path to tsconfig.json directory
        \\  --tokenize                   Print tokens instead of transpiling
        \\  --test262 <dir>              Run Test262 tests
        \\  -h, --help                   Show this help
        \\
    , .{});
}

test "basic" {
    try std.testing.expect(true);
}
