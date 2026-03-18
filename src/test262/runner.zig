const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const Scanner = @import("../lexer/scanner.zig").Scanner;

/// Test262 테스트 파일의 YAML 메타데이터
/// 각 .js 파일 상단의 /*--- ... ---*/ 블록을 파싱한 결과
pub const TestMetadata = struct {
    /// 파싱 단계에서 에러가 나야 하는 테스트인지
    /// negative.phase == "parse" && negative.type == "SyntaxError"이면 true
    is_negative_parse: bool = false,

    /// 에러 타입 (SyntaxError, ReferenceError 등)
    negative_type: ?[]const u8 = null,

    /// module 모드로 파싱해야 하는지
    is_module: bool = false,

    /// strict mode 관련 플래그
    is_only_strict: bool = false,
    is_no_strict: bool = false,

    /// 이 테스트가 요구하는 feature 목록
    /// (아직 미구현 feature면 스킵 판단에 사용)
    features: []const []const u8 = &.{},
};

/// Test262 테스트 하나의 실행 결과
pub const TestResult = enum {
    pass,
    fail,
    skip, // 아직 미지원 feature 등으로 스킵
};

/// Test262 전체 실행 결과 요약
pub const TestSummary = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,

    pub fn passRate(self: TestSummary) f64 {
        const effective = self.total - self.skipped;
        if (effective == 0) return 0.0;
        return @as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(effective)) * 100.0;
    }

    pub fn print(self: TestSummary, writer: anytype) !void {
        try writer.print(
            \\
            \\=== Test262 Results ===
            \\Total:   {d}
            \\Passed:  {d}
            \\Failed:  {d}
            \\Skipped: {d}
            \\Pass Rate: {d:.1}%
            \\
        , .{ self.total, self.passed, self.failed, self.skipped, self.passRate() });
    }
};

/// Test262 YAML frontmatter를 파싱한다.
///
/// 파일 내용에서 /*--- 와 ---*/ 사이의 YAML을 읽어
/// TestMetadata를 반환한다.
///
/// 예시:
/// ```
/// /*---
/// negative:
///   phase: parse
///   type: SyntaxError
/// flags: [module, onlyStrict]
/// ---*/
/// ```
pub fn parseMetadata(source: []const u8) TestMetadata {
    var meta = TestMetadata{};

    // /*--- 와 ---*/ 사이 추출
    const start_marker = "/*---";
    const end_marker = "---*/";

    const start_idx = mem.indexOf(u8, source, start_marker) orelse return meta;
    const after_start = start_idx + start_marker.len;
    const end_idx = mem.indexOf(u8, source[after_start..], end_marker) orelse return meta;
    const yaml_block = source[after_start .. after_start + end_idx];

    // 간이 YAML 파싱 (line-by-line)
    // 정식 YAML 파서가 아니라 Test262 메타데이터에 필요한 최소한만 파싱
    var in_negative = false;
    var lines = mem.splitScalar(u8, yaml_block, '\n');

    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");

        // negative: 블록 진입
        if (mem.startsWith(u8, trimmed, "negative:")) {
            in_negative = true;
            continue;
        }

        // negative 블록 내부
        if (in_negative) {
            if (mem.startsWith(u8, trimmed, "phase:")) {
                const value = mem.trim(u8, trimmed["phase:".len..], " \t");
                if (mem.eql(u8, value, "parse")) {
                    meta.is_negative_parse = true;
                }
            } else if (mem.startsWith(u8, trimmed, "type:")) {
                meta.negative_type = mem.trim(u8, trimmed["type:".len..], " \t");
            }
            // 들여쓰기가 없으면 negative 블록 탈출
            if (trimmed.len > 0 and !mem.startsWith(u8, line, " ") and !mem.startsWith(u8, line, "\t")) {
                if (!mem.startsWith(u8, trimmed, "phase:") and !mem.startsWith(u8, trimmed, "type:")) {
                    in_negative = false;
                }
            }
            if (mem.startsWith(u8, trimmed, "phase:") or mem.startsWith(u8, trimmed, "type:")) {
                continue;
            }
        }

        // flags: [module], flags: [onlyStrict], flags: [noStrict]
        if (mem.startsWith(u8, trimmed, "flags:")) {
            if (mem.indexOf(u8, trimmed, "module") != null) {
                meta.is_module = true;
            }
            if (mem.indexOf(u8, trimmed, "onlyStrict") != null) {
                meta.is_only_strict = true;
            }
            if (mem.indexOf(u8, trimmed, "noStrict") != null) {
                meta.is_no_strict = true;
            }
            in_negative = false;
        }
    }

    return meta;
}

/// 단일 Test262 테스트를 실행한다.
///
/// 아직 렉서/파서가 없으므로 placeholder.
/// 렉서 구현 후 여기에 실제 파싱 로직을 연결한다.
///
/// 판정 로직:
/// - is_negative_parse == true → 파서가 에러를 던지면 pass
/// - is_negative_parse == false → 파서가 에러 없이 완료되면 pass
/// 단일 Test262 테스트를 실행한다.
/// 렉서로 소스를 토크나이즈하고, 에러 발생 여부로 pass/fail을 판정.
///
/// 판정 로직:
/// - is_negative_parse == true → 렉서가 에러를 던지면 pass
/// - is_negative_parse == false → 렉서가 에러 없이 완료되면 pass
pub fn runTest(allocator: mem.Allocator, source: []const u8, meta: TestMetadata) TestResult {
    _ = meta.is_module; // 렉서 단계에서는 module/script 구분 없음

    // 렉서로 전체 토크나이즈
    var scanner = Scanner.init(allocator, source);
    defer scanner.deinit();

    var had_error = false;
    while (true) {
        scanner.next();
        if (scanner.token.kind == .syntax_error) {
            had_error = true;
            break;
        }
        if (scanner.token.kind == .eof) break;
    }

    if (meta.is_negative_parse) {
        return if (had_error) .pass else .fail;
    } else {
        return if (had_error) .fail else .pass;
    }
}

/// 디렉토리 내 모든 .js 파일을 재귀적으로 찾아 테스트를 실행한다.
pub fn runDirectory(allocator: mem.Allocator, dir_path: []const u8) !TestSummary {
    var summary = TestSummary{};
    var failed_list = std.ArrayList([]const u8).init(allocator);
    defer failed_list.deinit();

    var dir = try fs.openDirAbsolute(dir_path, .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.basename, ".js")) continue;

        // 파일 읽기
        const file = dir.openFile(entry.path, .{}) catch continue;
        defer file.close();
        const source = file.readToEndAlloc(allocator, 1024 * 1024) catch continue;
        defer allocator.free(source);

        // 메타데이터 파싱 & 테스트 실행
        const meta = parseMetadata(source);
        const result = runTest(allocator, source, meta);

        summary.total += 1;
        switch (result) {
            .pass => summary.passed += 1,
            .fail => {
                summary.failed += 1;
                try failed_list.append(try allocator.dupe(u8, entry.path));
            },
            .skip => summary.skipped += 1,
        }
    }

    // 실패 목록 출력
    if (failed_list.items.len > 0) {
        const stderr = std.io.getStdErr().writer();
        try stderr.print("\n--- Failed Tests ---\n", .{});
        for (failed_list.items) |path| {
            try stderr.print("  FAIL: {s}\n", .{path});
            allocator.free(path);
        }
    }

    return summary;
}

// ============================================================
// Tests
// ============================================================

test "parseMetadata: negative parse test" {
    const source =
        \\// some comment
        \\/*---
        \\negative:
        \\  phase: parse
        \\  type: SyntaxError
        \\---*/
        \\$DONOTEVALUATE();
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_negative_parse);
    try std.testing.expectEqualStrings("SyntaxError", meta.negative_type.?);
    try std.testing.expect(!meta.is_module);
}

test "parseMetadata: normal test (no negative)" {
    const source =
        \\/*---
        \\description: basic test
        \\---*/
        \\if (1 !== 1) throw new Test262Error();
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(!meta.is_negative_parse);
    try std.testing.expect(meta.negative_type == null);
}

test "parseMetadata: module flag" {
    const source =
        \\/*---
        \\flags: [module]
        \\---*/
        \\export default 42;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_module);
}

test "parseMetadata: onlyStrict flag" {
    const source =
        \\/*---
        \\flags: [onlyStrict]
        \\---*/
        \\var x = 1;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_only_strict);
    try std.testing.expect(!meta.is_no_strict);
}

test "parseMetadata: multiple flags" {
    const source =
        \\/*---
        \\flags: [module, noStrict]
        \\---*/
        \\export var x = 1;
    ;
    const meta = parseMetadata(source);
    try std.testing.expect(meta.is_module);
    try std.testing.expect(meta.is_no_strict);
}

test "passRate calculation" {
    const summary = TestSummary{
        .total = 100,
        .passed = 80,
        .failed = 10,
        .skipped = 10,
    };
    // 90개 중 80개 통과 = 88.8...%
    try std.testing.expectApproxEqAbs(@as(f64, 88.88), summary.passRate(), 0.1);
}
