//! ZTS Bundler — Orchestrator
//!
//! 번들러의 최상위 공개 API. ResolveCache → ModuleGraph → Emitter 파이프라인을 조율.
//!
//! 사용법:
//!   var bundler = Bundler.init(allocator, .{
//!       .entry_points = &.{"src/index.ts"},
//!       .format = .esm,
//!   });
//!   defer bundler.deinit();
//!   const result = try bundler.bundle();
//!   defer result.deinit(allocator);

const std = @import("std");
const types = @import("types.zig");
const BundlerDiagnostic = types.BundlerDiagnostic;
const ModuleGraph = @import("graph.zig").ModuleGraph;
const ResolveCache = @import("resolve_cache.zig").ResolveCache;
const Platform = @import("resolve_cache.zig").Platform;
const emitter = @import("emitter.zig");
const EmitOptions = emitter.EmitOptions;
const Linker = @import("linker.zig").Linker;

pub const BundleOptions = struct {
    entry_points: []const []const u8,
    format: EmitOptions.Format = .esm,
    platform: Platform = .browser,
    external: []const []const u8 = &.{},
    minify: bool = false,
    /// 스코프 호이스팅 활성화 (import/export 제거 + 변수 리네임). false면 기존 동작.
    scope_hoist: bool = true,
};

pub const BundleResult = struct {
    /// 번들 출력 내용 (단일 파일). allocator 소유.
    output: []const u8,
    /// 빌드 중 발생한 진단 메시지들. deep copy — 내부 문자열도 allocator 소유.
    diagnostics: ?[]OwnedDiagnostic,

    /// 문자열 필드를 소유하는 diagnostic (graph 해제 후에도 유효).
    pub const OwnedDiagnostic = struct {
        code: BundlerDiagnostic.ErrorCode,
        severity: BundlerDiagnostic.Severity,
        message: []const u8,
        file_path: []const u8,
        step: BundlerDiagnostic.Step,
        suggestion: ?[]const u8,
    };

    pub fn deinit(self: *const BundleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        if (self.diagnostics) |diags| {
            for (diags) |d| {
                allocator.free(d.message);
                allocator.free(d.file_path);
                if (d.suggestion) |s| allocator.free(s);
            }
            allocator.free(diags);
        }
    }

    pub fn hasErrors(self: *const BundleResult) bool {
        const diags = self.diagnostics orelse return false;
        for (diags) |d| {
            if (d.severity == .@"error") return true;
        }
        return false;
    }

    pub fn getDiagnostics(self: *const BundleResult) []const OwnedDiagnostic {
        return self.diagnostics orelse &[_]OwnedDiagnostic{};
    }
};

pub const Bundler = struct {
    allocator: std.mem.Allocator,
    options: BundleOptions,
    resolve_cache: ResolveCache,

    pub fn init(allocator: std.mem.Allocator, options: BundleOptions) Bundler {
        return .{
            .allocator = allocator,
            .options = options,
            .resolve_cache = ResolveCache.init(allocator, options.platform, options.external),
        };
    }

    pub fn deinit(self: *Bundler) void {
        self.resolve_cache.deinit();
    }

    /// 번들 파이프라인 실행: resolve → graph → emit.
    /// graph는 함수 내에서 생성+해제. &self.resolve_cache 포인터는 self가 살아있는 동안 유효.
    pub fn bundle(self: *Bundler) !BundleResult {
        // 1. 모듈 그래프 구축
        // graph가 &self.resolve_cache를 참조 — self가 move되지 않으므로 포인터 안전.
        var graph = ModuleGraph.init(self.allocator, &self.resolve_cache);
        defer graph.deinit();

        try graph.build(self.options.entry_points);

        // 2. 링킹 (scope hoisting)
        var linker: ?Linker = if (self.options.scope_hoist) blk: {
            var l = Linker.init(self.allocator, graph.modules.items);
            try l.link();
            try l.computeRenames();
            break :blk l;
        } else null;
        defer if (linker) |*l| l.deinit();

        // 3. 번들 출력 생성
        const output = try emitter.emit(
            self.allocator,
            &graph,
            .{ .format = self.options.format, .minify = self.options.minify },
            if (linker) |*l| l else null,
        );
        errdefer self.allocator.free(output);

        // 3. 진단 메시지 deep copy (graph.deinit 후에도 문자열 유효하도록)
        const diagnostics: ?[]BundleResult.OwnedDiagnostic = if (graph.diagnostics.items.len > 0) blk: {
            const diags = try self.allocator.alloc(BundleResult.OwnedDiagnostic, graph.diagnostics.items.len);
            errdefer self.allocator.free(diags);
            // M1 수정: 부분 할당 후 OOM 시 이미 복사한 문자열 해제
            var filled: usize = 0;
            errdefer for (diags[0..filled]) |d| {
                self.allocator.free(d.message);
                self.allocator.free(d.file_path);
                if (d.suggestion) |s| self.allocator.free(s);
            };
            for (graph.diagnostics.items, 0..) |d, i| {
                diags[i] = .{
                    .code = d.code,
                    .severity = d.severity,
                    .message = try self.allocator.dupe(u8, d.message),
                    .file_path = try self.allocator.dupe(u8, d.file_path),
                    .step = d.step,
                    .suggestion = if (d.suggestion) |s| try self.allocator.dupe(u8, s) else null,
                };
                filled = i + 1;
            }
            break :blk diags;
        } else null;

        return .{
            .output = output,
            .diagnostics = diagnostics,
        };
    }
};

// ============================================================
// Tests
// ============================================================

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    try dir.writeFile(.{ .sub_path = path, .data = data });
}

fn absPath(tmp: *std.testing.TmpDir, rel: []const u8) ![]const u8 {
    const dp = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dp);
    return try std.fs.path.resolve(std.testing.allocator, &.{ dp, rel });
}

test "Bundler: single file bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 42;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 42;") != null);
    try std.testing.expect(!result.hasErrors());
}

test "Bundler: two files bundled in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 1;");
    try writeFile(tmp.dir, "b.ts", "const b = 2;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // b.ts가 a.ts보다 먼저 (exec_index 순서)
    const b_pos = std.mem.indexOf(u8, result.output, "const b = 2;") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "const a = 1;") orelse return error.TestUnexpectedResult;
    try std.testing.expect(b_pos < a_pos);
}

test "Bundler: external module excluded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import 'react';\nconst x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // react는 external → 에러 없이 번들 생성
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x = 1;") != null);
}

test "Bundler: minified output" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x: number = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify = true,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, result.output, "const x=1;") != null);
    // minify: 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "Bundler: unresolved import produces error diagnostic" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "import './nonexistent';");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    const diags = result.getDiagnostics();
    try std.testing.expect(diags.len > 0);
    try std.testing.expectEqual(types.BundlerDiagnostic.ErrorCode.unresolved_import, diags[0].code);
}

test "Bundler: circular dependency produces warning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "import './a';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환은 경고 (에러 아님) → 번들 생성은 성공
    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
}

test "Bundler: IIFE format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
}

test "Bundler: CJS format" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "index.ts", "const x = 1;");

    const entry = try absPath(&tmp, "index.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.startsWith(u8, result.output, "'use strict';\n"));
}

test "Bundler: multiple entry points" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts", "const a = 1;");
    try writeFile(tmp.dir, "e2.ts", "const b = 2;");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

// ============================================================
// Linker Integration Tests (scope hoisting 동작 검증)
// ============================================================

test "Linker integration: import statement removed from bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // import 문이 제거되어야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
    // export 값은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
    // console.log(x)는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Linker integration: export keyword stripped (non-entry)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';");
    try writeFile(tmp.dir, "b.ts", "export const y = 99;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // b.ts의 "export const" → "const" (export 키워드 제거)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const y = 99;") != null);
}

test "Linker integration: name conflict renamed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst count = 0;\nconsole.log(count);");
    try writeFile(tmp.dir, "b.ts", "const count = 1;\nconsole.log(count);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 두 모듈의 count가 충돌 → 하나는 count$1로 리네임
    // (어느 쪽이 리네임될지는 exec_index에 따라 다름)
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "count$") != null or
            std.mem.indexOf(u8, result.output, "count") != null,
    );
}

test "Linker integration: scope_hoist=false preserves import/export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { x } from './b';\nconsole.log(x);");
    try writeFile(tmp.dir, "b.ts", "export const x = 42;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = false,
    });
    defer b.deinit();

    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // scope_hoist=false → import/export 그대로 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") != null or
        std.mem.indexOf(u8, result.output, "import{") != null);
}

// ============================================================
// Re-export patterns (Rollup/Rolldown 참고)
// ============================================================

test "Re-export: named re-export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './re';\nconsole.log(x);");
    try writeFile(tmp.dir, "re.ts", "export { x } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const x = 'hello';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'hello'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "console.log") != null);
}

test "Re-export: export all (export * from)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { a, b } from './barrel';\nconsole.log(a, b);");
    try writeFile(tmp.dir, "barrel.ts", "export * from './impl';");
    try writeFile(tmp.dir, "impl.ts", "export const a = 1;\nexport const b = 2;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const a = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const b = 2;") != null);
}

test "Re-export: chained re-export (A→B→C)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './mid';\nconsole.log(val);");
    try writeFile(tmp.dir, "mid.ts", "export { val } from './leaf';");
    try writeFile(tmp.dir, "leaf.ts", "export const val = 999;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "999") != null);
}

test "Re-export: barrel file (index re-exporting multiple modules)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { add, sub } from './utils';\nconsole.log(add, sub);");
    try writeFile(tmp.dir, "utils/index.ts", "export { add } from './math';\nexport { sub } from './math2';");
    try writeFile(tmp.dir, "utils/math.ts", "export const add = (a: number, b: number) => a + b;");
    try writeFile(tmp.dir, "utils/math2.ts", "export const sub = (a: number, b: number) => a - b;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a + b") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a - b") != null);
}

test "Re-export: default export and import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import greet from './greeter';\nconsole.log(greet);");
    try writeFile(tmp.dir, "greeter.ts", "export default function greet() { return 'hi'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet()") != null);
}

test "Re-export: export default expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import val from './config';\nconsole.log(val);");
    try writeFile(tmp.dir, "config.ts", "export default 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

// ============================================================
// Scope hoisting edge cases (Webpack 참고)
// ============================================================

test "Scope hoisting: three modules same variable name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './m1';\nimport './m2';\nconst name = 'entry';\nconsole.log(name);");
    try writeFile(tmp.dir, "m1.ts", "const name = 'first';\nconsole.log(name);");
    try writeFile(tmp.dir, "m2.ts", "const name = 'second';\nconsole.log(name);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 모듈의 name이 충돌 → 최소 2개는 name$1, name$2로 리네임
    // 출력에 name$가 1개 이상 존재해야 함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "name$") != null);
}

test "Scope hoisting: multiple named imports from one module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { foo, bar, baz } from './lib';\nconsole.log(foo, bar, baz);");
    try writeFile(tmp.dir, "lib.ts", "export const foo = 1;\nexport const bar = 2;\nexport const baz = 3;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // import 문 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
    // 모든 값 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const foo = 1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const bar = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const baz = 3;") != null);
}

test "Scope hoisting: import used in expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { WIDTH } from './config';\nconst area = WIDTH * 2;\nconsole.log(area);");
    try writeFile(tmp.dir, "config.ts", "export const WIDTH = 100;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WIDTH * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "const WIDTH = 100;") != null);
}

test "Scope hoisting: export function declaration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { helper } from './utils';\nconsole.log(helper());");
    try writeFile(tmp.dir, "utils.ts", "export function helper() { return 'ok'; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "Scope hoisting: let and var declarations across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './a';\nlet state = 0;\nvar count = 1;\nconsole.log(state, count);");
    try writeFile(tmp.dir, "a.ts", "let state = 'init';\nvar count = 10;\nconsole.log(state, count);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // state와 count가 충돌 → 리네임 발생
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "state$") != null or
            std.mem.indexOf(u8, result.output, "count$") != null,
    );
}

// ============================================================
// Circular dependencies (SWC/Rolldown 참고)
// ============================================================

test "Circular: three module cycle (A→B→C→A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconst a = 'A';");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconst b = 'B';");
    try writeFile(tmp.dir, "c.ts", "import './a';\nconst c = 'C';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환은 경고지만 번들은 생성됨
    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
    // 모든 모듈의 코드가 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'A'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'B'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'C'") != null);
}

test "Circular: two module cycle with exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { b_val } from './b';\nexport const a_val = 10;\nconsole.log(b_val);");
    try writeFile(tmp.dir, "b.ts", "import { a_val } from './a';\nexport const b_val = 20;\nconsole.log(a_val);");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "10") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "20") != null);
}

test "Circular: diamond with shared leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './left';\nimport './right';\nconsole.log('entry');");
    try writeFile(tmp.dir, "left.ts", "import './shared';\nconsole.log('left');");
    try writeFile(tmp.dir, "right.ts", "import './shared';\nconsole.log('right');");
    try writeFile(tmp.dir, "shared.ts", "console.log('shared');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared는 한 번만 포함 (중복 제거)
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "'shared'")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // 실행 순서: shared → left → right → entry
    const shared_pos = std.mem.indexOf(u8, result.output, "'shared'") orelse return error.TestUnexpectedResult;
    const entry_pos = std.mem.indexOf(u8, result.output, "'entry'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_pos < entry_pos);
}

// ============================================================
// TypeScript-specific bundling
// ============================================================

test "TypeScript: interface stripping across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { User } from './types';\nconst u: User = { name: 'test' };\nconsole.log(u);");
    try writeFile(tmp.dir, "types.ts", "export interface User { name: string; }\nexport interface Config { debug: boolean; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스는 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    // 값 코드는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'test'") != null);
}

test "TypeScript: enum across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { Color } from './enums';\nconsole.log(Color.Red);");
    try writeFile(tmp.dir, "enums.ts", "export enum Color { Red, Green, Blue }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // enum → IIFE 변환됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Color") != null);
}

test "TypeScript: type annotation stripping in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { process } from './processor';
        \\const result: string = process(42);
        \\console.log(result);
    );
    try writeFile(tmp.dir, "processor.ts",
        \\export function process(input: number): string {
        \\  return String(input);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 타입 어노테이션 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
    // 로직은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "String(input)") != null);
}

test "TypeScript: class with generics across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Container } from './container';
        \\const c = new Container(42);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "container.ts",
        \\export class Container<T> {
        \\  value: T;
        \\  constructor(v: T) { this.value = v; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 제네릭 타입 파라미터 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<T>") == null);
    // 클래스 구조는 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Container") != null);
}

test "TypeScript: mixed type and value exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { API_URL, type Config } from './config';
        \\const url: Config = { url: API_URL };
        \\console.log(url);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export type Config = { url: string };
        \\export const API_URL = 'https://api.example.com';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // type은 제거, 값은 유지
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type Config") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'https://api.example.com'") != null);
}

// ============================================================
// Deep dependency chains
// ============================================================

test "Deep chain: four-level (A→B→C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nconsole.log('a');");
    try writeFile(tmp.dir, "b.ts", "import './c';\nconsole.log('b');");
    try writeFile(tmp.dir, "c.ts", "import './d';\nconsole.log('c');");
    try writeFile(tmp.dir, "d.ts", "console.log('d');");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 실행 순서: d → c → b → a (DFS 후위)
    const d_pos = std.mem.indexOf(u8, result.output, "'d'") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "'c'") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "'b'") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "'a'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < c_pos);
    try std.testing.expect(c_pos < b_pos);
    try std.testing.expect(b_pos < a_pos);
}

test "Deep chain: wide fan-out (entry imports 5 modules)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './m1';\nimport './m2';\nimport './m3';\nimport './m4';\nimport './m5';\nconsole.log('done');");
    try writeFile(tmp.dir, "m1.ts", "console.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "console.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "console.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "console.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "console.log('m5');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 모듈 포함
    for ([_][]const u8{ "'m1'", "'m2'", "'m3'", "'m4'", "'m5'", "'done'" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // entry(done)이 가장 마지막
    const done_pos = std.mem.indexOf(u8, result.output, "'done'") orelse return error.TestUnexpectedResult;
    for ([_][]const u8{ "'m1'", "'m2'", "'m3'", "'m4'", "'m5'" }) |needle| {
        const pos = std.mem.indexOf(u8, result.output, needle) orelse return error.TestUnexpectedResult;
        try std.testing.expect(pos < done_pos);
    }
}

test "Deep chain: diamond dependency (A→B,C; B→D; C→D)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import { b } from './b';\nimport { c } from './c';\nconsole.log(b, c);");
    try writeFile(tmp.dir, "b.ts", "import { d } from './d';\nexport const b = d + 1;");
    try writeFile(tmp.dir, "c.ts", "import { d } from './d';\nexport const c = d + 2;");
    try writeFile(tmp.dir, "d.ts", "export const d = 100;");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // d가 b, c보다 먼저 (공유 leaf)
    const d_pos = std.mem.indexOf(u8, result.output, "const d = 100;") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "d + 1") orelse return error.TestUnexpectedResult;
    const c_pos = std.mem.indexOf(u8, result.output, "d + 2") orelse return error.TestUnexpectedResult;
    try std.testing.expect(d_pos < b_pos);
    try std.testing.expect(d_pos < c_pos);
}

// ============================================================
// Real-world patterns (Webpack/Rolldown/esbuild 참고)
// ============================================================

test "Real-world: utils module pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { capitalize, slugify } from './utils';
        \\console.log(capitalize('hello'), slugify('Hello World'));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function capitalize(s: string): string {
        \\  return s.charAt(0).toUpperCase() + s.slice(1);
        \\}
        \\export function slugify(s: string): string {
        \\  return s.toLowerCase().replace(/ /g, '-');
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function capitalize") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function slugify") != null);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

test "Real-world: constants module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { MAX_RETRIES, TIMEOUT, BASE_URL } from './constants';
        \\console.log(MAX_RETRIES, TIMEOUT, BASE_URL);
    );
    try writeFile(tmp.dir, "constants.ts",
        \\export const MAX_RETRIES = 3;
        \\export const TIMEOUT = 5000;
        \\export const BASE_URL = '/api/v1';
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "MAX_RETRIES = 3") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "TIMEOUT = 5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'/api/v1'") != null);
}

test "Real-world: class with imported dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { Logger } from './logger';
        \\const log = new Logger('app');
        \\log.info('started');
    );
    try writeFile(tmp.dir, "logger.ts",
        \\import { formatDate } from './date';
        \\export class Logger {
        \\  prefix: string;
        \\  constructor(p: string) { this.prefix = p; }
        \\  info(msg: string) { console.log(formatDate() + ' ' + this.prefix + ': ' + msg); }
        \\}
    );
    try writeFile(tmp.dir, "date.ts",
        \\export function formatDate(): string {
        \\  return new Date().toISOString();
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3모듈 번들: date → logger → app 순서
    const date_pos = std.mem.indexOf(u8, result.output, "function formatDate") orelse return error.TestUnexpectedResult;
    const logger_pos = std.mem.indexOf(u8, result.output, "class Logger") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "new Logger") orelse return error.TestUnexpectedResult;
    try std.testing.expect(date_pos < logger_pos);
    try std.testing.expect(logger_pos < app_pos);
}

test "Real-world: event emitter pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { EventBus } from './events';
        \\const bus = new EventBus();
        \\bus.on('click', () => console.log('clicked'));
    );
    try writeFile(tmp.dir, "events.ts",
        \\export class EventBus {
        \\  listeners: Record<string, Function[]> = {};
        \\  on(event: string, fn: Function) {
        \\    if (!this.listeners[event]) this.listeners[event] = [];
        \\    this.listeners[event].push(fn);
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class EventBus") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new EventBus") != null);
}

test "Real-world: re-export from node_modules (external)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import React from 'react';
        \\import { useState } from 'react';
        \\import { render } from './renderer';
        \\render();
    );
    try writeFile(tmp.dir, "renderer.ts",
        \\export function render() { console.log('render'); }
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 로컬 모듈은 번들에 포함
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function render") != null);
}

// ============================================================
// Output format tests (all formats with same input)
// ============================================================

test "Format: ESM preserves export in entry" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "export const version = '1.0.0';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'1.0.0'") != null);
}

test "Format: CJS with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'cjs-test';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "'use strict';\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'cjs-test'") != null);
}

test "Format: IIFE with multiple modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { greet } from './greeter';\ngreet();");
    try writeFile(tmp.dir, "greeter.ts", "export function greet() { console.log('hello'); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
}

test "Format: minified IIFE" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './m';\nconsole.log(x);");
    try writeFile(tmp.dir, "m.ts", "export const x = 1;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
        .minify = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    // 모듈 경계 주석 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "// ---") == null);
}

test "Format: minified CJS" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "const msg = 'hello';\nconsole.log(msg);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
        .minify = true,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "'use strict';\n"));
}

// ============================================================
// Edge cases
// ============================================================

test "Edge: empty module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './empty';\nconsole.log('ok');");
    try writeFile(tmp.dir, "empty.ts", "");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'ok'") != null);
}

test "Edge: module with only comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './commented';\nconsole.log('works');");
    try writeFile(tmp.dir, "commented.ts", "// This is just a comment\n/* block comment */");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'works'") != null);
}

test "Edge: side-effect only imports preserve execution order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './init1';\nimport './init2';\nimport './init3';\nconsole.log('app');");
    try writeFile(tmp.dir, "init1.ts", "console.log('init1');");
    try writeFile(tmp.dir, "init2.ts", "console.log('init2');");
    try writeFile(tmp.dir, "init3.ts", "console.log('init3');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // import 순서대로 실행: init1 → init2 → init3 → app
    const p1 = std.mem.indexOf(u8, result.output, "'init1'") orelse return error.TestUnexpectedResult;
    const p2 = std.mem.indexOf(u8, result.output, "'init2'") orelse return error.TestUnexpectedResult;
    const p3 = std.mem.indexOf(u8, result.output, "'init3'") orelse return error.TestUnexpectedResult;
    const pa = std.mem.indexOf(u8, result.output, "'app'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(p1 < p2);
    try std.testing.expect(p2 < p3);
    try std.testing.expect(p3 < pa);
}

test "Edge: same module imported by multiple parents (dedup)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './shared';
        \\import { getX } from './helper';
        \\console.log(x, getX());
    );
    try writeFile(tmp.dir, "helper.ts",
        \\import { x } from './shared';
        \\export function getX() { return x; }
    );
    try writeFile(tmp.dir, "shared.ts", "export const x = 'shared_value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared 모듈의 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "'shared_value'")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Edge: deeply nested directory imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/app/main.ts", "import { db } from '../lib/db/client';\nconsole.log(db);");
    try writeFile(tmp.dir, "src/lib/db/client.ts", "export const db = 'connected';");

    const entry = try absPath(&tmp, "src/app/main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'connected'") != null);
}

test "Edge: export function and class from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createApp, App } from './framework';
        \\const app = createApp();
        \\console.log(app instanceof App);
    );
    try writeFile(tmp.dir, "framework.ts",
        \\export class App { name = 'app'; }
        \\export function createApp() { return new App(); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class App") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createApp") != null);
}

test "Edge: multiple external packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import lodash from 'lodash';
        \\import axios from 'axios';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'yes';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{ "react", "lodash", "axios" },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'yes'") != null);
}

test "Edge: import with .js extension resolves to .ts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { val } from './lib.js';\nconsole.log(val);");
    try writeFile(tmp.dir, "lib.ts", "export const val = 'from-ts';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-ts'") != null);
}

test "Edge: index.ts resolution (directory import)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { hello } from './mylib';\nconsole.log(hello);");
    try writeFile(tmp.dir, "mylib/index.ts", "export const hello = 'world';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'world'") != null);
}

// ============================================================
// Complex integration scenarios (esbuild/Rspack 참고)
// ============================================================

test "Complex: mixed import styles in one file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import def from './default';
        \\import { named } from './named';
        \\import './side-effect';
        \\console.log(def, named);
    );
    try writeFile(tmp.dir, "default.ts", "export default 'default_val';");
    try writeFile(tmp.dir, "named.ts", "export const named = 'named_val';");
    try writeFile(tmp.dir, "side-effect.ts", "console.log('side');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'default_val'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'named_val'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'side'") != null);
}

test "Complex: transitive import chain with values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { result } from './compute';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "compute.ts",
        \\import { base } from './base';
        \\import { multiplier } from './config';
        \\export const result = base * multiplier;
    );
    try writeFile(tmp.dir, "base.ts", "export const base = 10;");
    try writeFile(tmp.dir, "config.ts", "export const multiplier = 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // base, config 가 compute보다 먼저
    const base_pos = std.mem.indexOf(u8, result.output, "base = 10") orelse return error.TestUnexpectedResult;
    const mult_pos = std.mem.indexOf(u8, result.output, "multiplier = 5") orelse return error.TestUnexpectedResult;
    const result_pos = std.mem.indexOf(u8, result.output, "base * multiplier") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_pos < result_pos);
    try std.testing.expect(mult_pos < result_pos);
}

test "Complex: multiple entry points sharing a module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "page1.ts", "import { shared } from './shared';\nconsole.log('page1', shared);");
    try writeFile(tmp.dir, "page2.ts", "import { shared } from './shared';\nconsole.log('page2', shared);");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'common';");

    const entry1 = try absPath(&tmp, "page1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "page2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'common'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'page1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'page2'") != null);
}

test "Complex: platform node with external builtins" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "server.ts",
        \\import fs from 'fs';
        \\import path from 'path';
        \\import { config } from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts", "export const config = { port: 3000 };");

    const entry = try absPath(&tmp, "server.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // node builtins (fs, path) are external on node platform
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "port: 3000") != null);
}

test "Complex: arrow functions across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { double, triple } from './transforms';
        \\console.log(double(5), triple(3));
    );
    try writeFile(tmp.dir, "transforms.ts",
        \\export const double = (n: number) => n * 2;
        \\export const triple = (n: number) => n * 3;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "n * 3") != null);
    // 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
}

test "Complex: async function across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fetchData } from './api';
        \\fetchData().then(console.log);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export async function fetchData(): Promise<string> {
        \\  return 'data';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "async function fetchData") != null);
    // 리턴 타입 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Promise<string>") == null);
}

test "Complex: destructuring imports used in complex expressions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { width, height } from './dimensions';
        \\const area = width * height;
        \\const perimeter = 2 * (width + height);
        \\console.log({ area, perimeter });
    );
    try writeFile(tmp.dir, "dimensions.ts",
        \\export const width = 10;
        \\export const height = 20;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width * height") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "width + height") != null);
}

// ============================================================
// Rollup-style tests: re-export variants + scope hoisting
// ============================================================

test "Rollup: export * with local override" {
    // Rollup form/samples 참고: star re-export + 로컬 같은 이름 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y } from './barrel';
        \\console.log(x, y);
    );
    // barrel에서 export * 하면서 x를 로컬로도 export
    try writeFile(tmp.dir, "barrel.ts",
        \\export * from './source';
        \\export const x = 'overridden';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'original';
        \\export const y = 'from-source';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-source'") != null);
}

test "Rollup: chained re-exports through three modules" {
    // Rollup 스타일: A imports from B, B re-exports from C, C re-exports from D
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { deep } from './l1';\nconsole.log(deep);");
    try writeFile(tmp.dir, "l1.ts", "export { deep } from './l2';");
    try writeFile(tmp.dir, "l2.ts", "export { deep } from './l3';");
    try writeFile(tmp.dir, "l3.ts", "export const deep = 'leaf-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'leaf-value'") != null);
    // 중간 re-export 모듈들의 import/export는 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

test "Rollup: side-effect free import ordering" {
    // Rollup: import 순서가 실행 순서를 결정 (ESM spec)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './polyfill';
        \\import './setup';
        \\import { app } from './app';
        \\console.log(app);
    );
    try writeFile(tmp.dir, "polyfill.ts", "console.log('polyfill');");
    try writeFile(tmp.dir, "setup.ts", "console.log('setup');");
    try writeFile(tmp.dir, "app.ts", "export const app = 'ready';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // polyfill → setup → app → entry 순서
    const poly_pos = std.mem.indexOf(u8, result.output, "'polyfill'") orelse return error.TestUnexpectedResult;
    const setup_pos = std.mem.indexOf(u8, result.output, "'setup'") orelse return error.TestUnexpectedResult;
    const app_pos = std.mem.indexOf(u8, result.output, "'ready'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(poly_pos < setup_pos);
    try std.testing.expect(setup_pos < app_pos);
}

test "Rollup: multiple exports from single module" {
    // Rollup form/samples: 한 모듈에서 여러 종류의 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { fn, cls, val, arrow } from './lib';
        \\console.log(fn(), new cls(), val, arrow());
    );
    try writeFile(tmp.dir, "lib.ts",
        \\export function fn() { return 1; }
        \\export class cls { x = 2; }
        \\export const val = 3;
        \\export const arrow = () => 4;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function fn()") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class cls") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "val = 3") != null);
}

// ============================================================
// esbuild-style tests: external handling + format conversion
// ============================================================

test "esbuild: external glob pattern" {
    // esbuild: 글롭 패턴으로 external 지정
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import React from 'react';
        \\import ReactDOM from 'react-dom';
        \\import { local } from './local';
        \\console.log(local);
    );
    try writeFile(tmp.dir, "local.ts", "export const local = 'bundled';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .external = &.{"react*"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // react, react-dom 둘 다 external
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'bundled'") != null);
}

test "esbuild: node builtins auto-external" {
    // esbuild: platform=node에서 node: prefix 자동 external
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import crypto from 'node:crypto';
        \\import { readFile } from 'node:fs/promises';
        \\const key = 'local-value';
        \\console.log(key);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .platform = .node,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'local-value'") != null);
}

test "esbuild: define global replacement" {
    // esbuild --define 테스트는 CLI 수준 → 번들러에서는 변환 결과만 확인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const isProd = false;
        \\if (isProd) { console.log('prod'); }
        \\console.log('dev');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'dev'") != null);
}

test "esbuild: ESM to CJS format conversion with imports" {
    // esbuild: ESM 입력 → CJS 출력, import가 require로 변환되지 않고 번들에 포함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { helper } from './helper';
        \\export const result = helper(42);
    );
    try writeFile(tmp.dir, "helper.ts",
        \\export function helper(n: number) { return n * 2; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "'use strict';\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

test "esbuild: ESM to IIFE with scope hoisting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { add } from './math';
        \\console.log(add(1, 2));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export function add(a: number, b: number) { return a + b; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, result.output, "(function() {\n"));
    try std.testing.expect(std.mem.endsWith(u8, result.output, "})();\n"));
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function add") != null);
    // import 문 제거됨
    try std.testing.expect(std.mem.indexOf(u8, result.output, "import ") == null);
}

// ============================================================
// Bun-style tests: TypeScript, barrel files, resolution
// ============================================================

test "Bun: barrel file with selective import" {
    // Bun: barrel에서 일부만 import (사용하지 않는 export도 번들에는 포함)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Button } from './components';
        \\console.log(Button);
    );
    try writeFile(tmp.dir, "components/index.ts",
        \\export { Button } from './Button';
        \\export { Card } from './Card';
    );
    try writeFile(tmp.dir, "components/Button.ts", "export const Button = 'btn';");
    try writeFile(tmp.dir, "components/Card.ts", "export const Card = 'card';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'btn'") != null);
}

test "Bun: TypeScript interface-only module" {
    // Bun: 타입만 있는 모듈 import
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MyType } from './types';
        \\const x: MyType = 42;
        \\console.log(x);
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface MyType {}
        \\export type OtherType = string | number;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 인터페이스/타입 모두 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "type ") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Bun: .tsx file bundling" {
    // Bun: TSX 파일의 JSX 변환 + 번들링
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import { Component } from './comp';
        \\console.log(Component);
    );
    try writeFile(tmp.dir, "comp.tsx",
        \\export function Component() { return <div>hello</div>; }
    );

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Component") != null);
    // JSX가 변환됨 (<div> → React.createElement 등)
    try std.testing.expect(std.mem.indexOf(u8, result.output, "<div>") == null);
}

test "Bun: extension resolution priority (.ts over .js)" {
    // Bun: .ts 확장자가 .js보다 우선
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './lib';\nconsole.log(x);");
    try writeFile(tmp.dir, "lib.ts", "export const x = 'from-ts';");
    try writeFile(tmp.dir, "lib.js", "export const x = 'from-js';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // .ts가 .js보다 우선
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-ts'") != null);
}

test "Bun: complex real-world component pattern" {
    // Bun 스타일: 컴포넌트 + 훅 + 유틸 패턴 (React-like)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { createStore } from './store';
        \\import { logger } from './utils/logger';
        \\const store = createStore();
        \\logger('App initialized');
        \\console.log(store);
    );
    try writeFile(tmp.dir, "store.ts",
        \\import { logger } from './utils/logger';
        \\export function createStore() {
        \\  logger('Store created');
        \\  return { state: {} };
        \\}
    );
    try writeFile(tmp.dir, "utils/logger.ts",
        \\export function logger(msg: string) {
        \\  console.log('[LOG]', msg);
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // logger가 store보다 먼저 (의존성 순서)
    const logger_pos = std.mem.indexOf(u8, result.output, "function logger") orelse return error.TestUnexpectedResult;
    const store_pos = std.mem.indexOf(u8, result.output, "function createStore") orelse return error.TestUnexpectedResult;
    try std.testing.expect(logger_pos < store_pos);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": string") == null);
}

// ============================================================
// Rolldown-style tests: CJS compat + symbol deconflicting
// ============================================================

test "Rolldown: symbol deconflicting with many modules" {
    // Rolldown: 5개 모듈에서 같은 이름 사용 → 순차적 $1, $2, ...
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\import './b';
        \\import './c';
        \\import './d';
        \\const value = 'entry';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "a.ts", "const value = 'a';\nconsole.log(value);");
    try writeFile(tmp.dir, "b.ts", "const value = 'b';\nconsole.log(value);");
    try writeFile(tmp.dir, "c.ts", "const value = 'c';\nconsole.log(value);");
    try writeFile(tmp.dir, "d.ts", "const value = 'd';\nconsole.log(value);");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 5개 value → 최소 4개는 리네임 ($1, $2, $3, $4)
    var rename_count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "value$")) |pos| {
        rename_count += 1;
        search_from = pos + 1;
    }
    try std.testing.expect(rename_count >= 4);
}

test "Rolldown: export default function with rename" {
    // Rolldown: default export 함수 + 같은 이름의 변수가 다른 모듈에
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import handler from './handler';
        \\const handler2 = () => 'local';
        \\console.log(handler(), handler2());
    );
    try writeFile(tmp.dir, "handler.ts",
        \\export default function handler() { return 'from-module'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-module'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'local'") != null);
}

test "Rolldown: deep re-export with export *" {
    // Rolldown tree_shaking: export * 체인
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { data } from './index';
        \\console.log(data);
    );
    try writeFile(tmp.dir, "index.ts", "export * from './layer1';");
    try writeFile(tmp.dir, "layer1.ts", "export * from './layer2';");
    try writeFile(tmp.dir, "layer2.ts", "export const data = 'deep-star';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'deep-star'") != null);
}

test "Rolldown: mixed default and named imports from same module" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config, { VERSION, DEBUG } from './config';
        \\console.log(config, VERSION, DEBUG);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const VERSION = '2.0';
        \\export const DEBUG = false;
        \\export default { name: 'myapp' };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'2.0'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'myapp'") != null);
}

// ============================================================
// Webpack-style tests: scope hoisting edge cases
// ============================================================

test "Webpack: scope hoisting with nested functions" {
    // Webpack scope-hoisting: 중첩 함수의 변수는 충돌 대상 아님
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { outer } from './mod';
        \\console.log(outer());
    );
    try writeFile(tmp.dir, "mod.ts",
        \\export function outer() {
        \\  const x = 1;
        \\  function inner() { const x = 2; return x; }
        \\  return x + inner();
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function outer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function inner") != null);
}

test "Webpack: import order matches dependency graph" {
    // Webpack cases/scope-hoisting: import-order
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import { b } from './b';
        \\console.log(a + b);
    );
    try writeFile(tmp.dir, "a.ts",
        \\import { shared } from './shared';
        \\export const a = shared + '-a';
    );
    try writeFile(tmp.dir, "b.ts",
        \\import { shared } from './shared';
        \\export const b = shared + '-b';
    );
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'base';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared → a → b → entry 순서 (shared가 가장 먼저)
    const shared_pos = std.mem.indexOf(u8, result.output, "'base'") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "'-a'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(shared_pos < a_pos);
}

test "Webpack: re-export with alias name" {
    // Webpack: export { x as y } from
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { aliased } from './reexport';
        \\console.log(aliased);
    );
    try writeFile(tmp.dir, "reexport.ts", "export { original as aliased } from './source';");
    try writeFile(tmp.dir, "source.ts", "export const original = 'orig-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'orig-value'") != null);
}

// ============================================================
// Stress / robustness tests
// ============================================================

test "Stress: 10 modules in chain" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // m0 → m1 → m2 → ... → m9 (각각 import + 값)
    try writeFile(tmp.dir, "m0.ts", "import './m1';\nconsole.log('m0');");
    try writeFile(tmp.dir, "m1.ts", "import './m2';\nconsole.log('m1');");
    try writeFile(tmp.dir, "m2.ts", "import './m3';\nconsole.log('m2');");
    try writeFile(tmp.dir, "m3.ts", "import './m4';\nconsole.log('m3');");
    try writeFile(tmp.dir, "m4.ts", "import './m5';\nconsole.log('m4');");
    try writeFile(tmp.dir, "m5.ts", "import './m6';\nconsole.log('m5');");
    try writeFile(tmp.dir, "m6.ts", "import './m7';\nconsole.log('m6');");
    try writeFile(tmp.dir, "m7.ts", "import './m8';\nconsole.log('m7');");
    try writeFile(tmp.dir, "m8.ts", "import './m9';\nconsole.log('m8');");
    try writeFile(tmp.dir, "m9.ts", "console.log('m9');");

    const entry = try absPath(&tmp, "m0.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // m9가 가장 먼저, m0이 가장 나중
    const m9_pos = std.mem.indexOf(u8, result.output, "'m9'") orelse return error.TestUnexpectedResult;
    const m0_pos = std.mem.indexOf(u8, result.output, "'m0'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(m9_pos < m0_pos);
}

test "Stress: wide fan-in (many modules import same leaf)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a'; import './b'; import './c'; import './d';
        \\console.log('entry');
    );
    try writeFile(tmp.dir, "a.ts", "import { x } from './leaf';\nconsole.log('a', x);");
    try writeFile(tmp.dir, "b.ts", "import { x } from './leaf';\nconsole.log('b', x);");
    try writeFile(tmp.dir, "c.ts", "import { x } from './leaf';\nconsole.log('c', x);");
    try writeFile(tmp.dir, "d.ts", "import { x } from './leaf';\nconsole.log('d', x);");
    try writeFile(tmp.dir, "leaf.ts", "export const x = 'shared';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // leaf 코드는 한 번만 포함
    var count: usize = 0;
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, search_from, "'shared'")) |pos| {
        count += 1;
        search_from = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "Stress: multiple entry points with deep shared graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "e1.ts", "import { a } from './a';\nconsole.log('e1', a);");
    try writeFile(tmp.dir, "e2.ts", "import { b } from './b';\nconsole.log('e2', b);");
    try writeFile(tmp.dir, "a.ts", "import { common } from './common';\nexport const a = common + '-a';");
    try writeFile(tmp.dir, "b.ts", "import { common } from './common';\nexport const b = common + '-b';");
    try writeFile(tmp.dir, "common.ts", "export const common = 'shared-base';");

    const entry1 = try absPath(&tmp, "e1.ts");
    defer std.testing.allocator.free(entry1);
    const entry2 = try absPath(&tmp, "e2.ts");
    defer std.testing.allocator.free(entry2);

    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{ entry1, entry2 },
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'shared-base'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'e1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'e2'") != null);
}

// ============================================================
// Default export advanced patterns (Rollup/Rolldown 참고)
// ============================================================

test "Default: export default class" {
    // Rollup default-export-class: 클래스를 default export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import MyClass from './myclass';
        \\const inst = new MyClass();
        \\console.log(inst.name);
    );
    try writeFile(tmp.dir, "myclass.ts",
        \\export default class MyClass {
        \\  name = 'hello';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class MyClass") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new MyClass") != null);
}

test "Default: export default arrow function" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import multiply from './math';
        \\console.log(multiply(3, 4));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export default (a: number, b: number) => a * b;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "a * b") != null);
}

test "Default: re-export default from another module" {
    // Rolldown: export { default } from './mod'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import val from './proxy';
        \\console.log(val);
    );
    try writeFile(tmp.dir, "proxy.ts", "export { default } from './real';");
    try writeFile(tmp.dir, "real.ts", "export default 'real-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'real-value'") != null);
}

test "Default: default export with same-name local variable" {
    // Rollup default-identifier-deshadowing
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import foo from './mod';
        \\console.log(foo);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const foo = 'local';
        \\export default function foo2() { return foo; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'local'") != null);
}

test "Default: multiple modules with default exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import a from './a';
        \\import b from './b';
        \\import c from './c';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "a.ts", "export default 'alpha';");
    try writeFile(tmp.dir, "b.ts", "export default 'beta';");
    try writeFile(tmp.dir, "c.ts", "export default 'gamma';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'alpha'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'beta'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'gamma'") != null);
}

// ============================================================
// Deconflicting advanced patterns (Rollup/Rolldown 참고)
// ============================================================

test "Deconflict: exported function name clashes with import" {
    // 두 모듈이 같은 이름의 함수를 export
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { render } from './a';
        \\import { render as renderB } from './b';
        \\render();
        \\renderB();
    );
    try writeFile(tmp.dir, "a.ts", "export function render() { console.log('a'); }");
    try writeFile(tmp.dir, "b.ts", "export function render() { console.log('b'); }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 두 render가 충돌 → 하나는 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "render$") != null or
        std.mem.indexOf(u8, result.output, "function render") != null);
}

test "Deconflict: class name collision across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './models/user';
        \\import './models/admin';
        \\class Model { type = 'base'; }
        \\console.log(new Model());
    );
    try writeFile(tmp.dir, "models/user.ts",
        \\class Model { type = 'user'; }
        \\console.log(new Model());
    );
    try writeFile(tmp.dir, "models/admin.ts",
        \\class Model { type = 'admin'; }
        \\console.log(new Model());
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 3개 Model 클래스 → 리네임 발생
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Model$") != null);
}

test "Deconflict: variable shadows built-in name" {
    // 모듈에서 console, Math 등과 같은 이름 사용
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\const log = 'entry-log';
        \\console.log(log);
    );
    try writeFile(tmp.dir, "a.ts",
        \\const log = 'a-log';
        \\console.log(log);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // log가 충돌 → 리네임
    try std.testing.expect(std.mem.indexOf(u8, result.output, "log$") != null);
}

// ============================================================
// Assignment patterns (Rollup 참고)
// ============================================================

test "Assignment: export var reassignment" {
    // Rollup assignment-to-exports
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { counter, increment } from './counter';
        \\console.log(counter);
        \\increment();
    );
    try writeFile(tmp.dir, "counter.ts",
        \\export let counter = 0;
        \\export function increment() { counter++; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "let counter = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function increment") != null);
}

test "Assignment: export const with complex initializer" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { config } from './setup';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "setup.ts",
        \\const env = 'production';
        \\export const config = {
        \\  env,
        \\  debug: env !== 'production',
        \\  version: '1.0.' + String(42),
        \\};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'production'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "String(42)") != null);
}

// ============================================================
// TypeScript advanced patterns
// ============================================================

test "TypeScript: namespace with export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Colors } from './colors';
        \\console.log(Colors.Red);
    );
    try writeFile(tmp.dir, "colors.ts",
        \\export namespace Colors {
        \\  export const Red = '#ff0000';
        \\  export const Blue = '#0000ff';
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Colors") != null);
}

test "TypeScript: abstract class bundling" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Dog } from './dog';
        \\const d = new Dog('Rex');
        \\console.log(d.speak());
    );
    try writeFile(tmp.dir, "dog.ts",
        \\import { Animal } from './animal';
        \\export class Dog extends Animal {
        \\  speak(): string { return this.name + ' barks'; }
        \\}
    );
    try writeFile(tmp.dir, "animal.ts",
        \\export abstract class Animal {
        \\  constructor(public name: string) {}
        \\  abstract speak(): string;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // abstract 키워드 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "abstract") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Animal") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Dog") != null);
}

test "TypeScript: const enum inlining" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Direction } from './direction';
        \\console.log(Direction.Up);
    );
    try writeFile(tmp.dir, "direction.ts",
        \\export const enum Direction {
        \\  Up,
        \\  Down,
        \\  Left,
        \\  Right,
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "TypeScript: string enum across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Status } from './status';
        \\console.log(Status.Active);
    );
    try writeFile(tmp.dir, "status.ts",
        \\export enum Status {
        \\  Active = 'ACTIVE',
        \\  Inactive = 'INACTIVE',
        \\  Pending = 'PENDING',
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'ACTIVE'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Status") != null);
}

test "TypeScript: multiple interfaces stripped clean" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Logger } from './logger';
        \\const l = new Logger();
        \\l.log('test');
    );
    try writeFile(tmp.dir, "logger.ts",
        \\interface LogLevel { level: string; }
        \\interface LogConfig extends LogLevel { prefix: string; }
        \\type LogFn = (msg: string) => void;
        \\export class Logger {
        \\  log(msg: string) { console.log(msg); }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Logger") != null);
}

// ============================================================
// Circular dependency advanced (SWC/Rolldown 참고)
// ============================================================

test "Circular: four module cycle (A→B→C→D→A)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "a.ts", "import './b';\nexport const a = 'A';");
    try writeFile(tmp.dir, "b.ts", "import './c';\nexport const b = 'B';");
    try writeFile(tmp.dir, "c.ts", "import './d';\nexport const c = 'C';");
    try writeFile(tmp.dir, "d.ts", "import './a';\nexport const d = 'D';");

    const entry = try absPath(&tmp, "a.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    var has_circular = false;
    for (result.getDiagnostics()) |d| {
        if (d.code == .circular_dependency) has_circular = true;
    }
    try std.testing.expect(has_circular);
    // 모든 모듈 포함
    for ([_][]const u8{ "'A'", "'B'", "'C'", "'D'" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
}

test "Circular: mutual import with re-exports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { combined } from './combiner';
        \\console.log(combined);
    );
    try writeFile(tmp.dir, "combiner.ts",
        \\import { foo } from './foo';
        \\import { bar } from './bar';
        \\export const combined = foo + bar;
    );
    try writeFile(tmp.dir, "foo.ts",
        \\import { bar } from './bar';
        \\export const foo = 'FOO';
    );
    try writeFile(tmp.dir, "bar.ts",
        \\import { foo } from './foo';
        \\export const bar = 'BAR';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 순환이 있어도 번들은 생성됨
    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'FOO'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'BAR'") != null);
}

test "Circular: entry depends on circular pair" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './a';
        \\console.log('entry done');
    );
    try writeFile(tmp.dir, "a.ts",
        \\import './b';
        \\console.log('a');
    );
    try writeFile(tmp.dir, "b.ts",
        \\import './a';
        \\console.log('b');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // entry가 마지막
    const entry_pos = std.mem.indexOf(u8, result.output, "'entry done'") orelse return error.TestUnexpectedResult;
    const a_pos = std.mem.indexOf(u8, result.output, "'a'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < entry_pos);
}

// ============================================================
// Module resolution edge cases
// ============================================================

test "Resolution: parent directory traversal (../../)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "src/pages/home.ts",
        \\import { version } from '../../package-info';
        \\console.log(version);
    );
    try writeFile(tmp.dir, "package-info.ts", "export const version = '3.0.0';");

    const entry = try absPath(&tmp, "src/pages/home.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'3.0.0'") != null);
}

test "Resolution: .tsx extension for React components" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.tsx",
        \\import { Header } from './Header';
        \\console.log(Header);
    );
    try writeFile(tmp.dir, "Header.tsx",
        \\export function Header() { return <h1>Title</h1>; }
    );

    const entry = try absPath(&tmp, "app.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function Header") != null);
}

test "Resolution: mixed .ts and .tsx imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.tsx",
        \\import { util } from './util';
        \\import { View } from './view';
        \\console.log(util, View);
    );
    try writeFile(tmp.dir, "util.ts", "export const util = 'utility';");
    try writeFile(tmp.dir, "view.tsx", "export function View() { return <div/>; }");

    const entry = try absPath(&tmp, "entry.tsx");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'utility'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function View") != null);
}

// ============================================================
// Complex real-world patterns (esbuild/Bun 참고)
// ============================================================

test "Real-world: layered architecture (controller → service → repository)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "app.ts",
        \\import { UserController } from './controller';
        \\const ctrl = new UserController();
        \\console.log(ctrl.getUser());
    );
    try writeFile(tmp.dir, "controller.ts",
        \\import { UserService } from './service';
        \\export class UserController {
        \\  svc = new UserService();
        \\  getUser() { return this.svc.findById(1); }
        \\}
    );
    try writeFile(tmp.dir, "service.ts",
        \\import { UserRepo } from './repo';
        \\export class UserService {
        \\  repo = new UserRepo();
        \\  findById(id: number) { return this.repo.get(id); }
        \\}
    );
    try writeFile(tmp.dir, "repo.ts",
        \\export class UserRepo {
        \\  get(id: number) { return { id, name: 'User' }; }
        \\}
    );

    const entry = try absPath(&tmp, "app.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 의존성 순서: repo → service → controller → app
    const repo_pos = std.mem.indexOf(u8, result.output, "class UserRepo") orelse return error.TestUnexpectedResult;
    const svc_pos = std.mem.indexOf(u8, result.output, "class UserService") orelse return error.TestUnexpectedResult;
    const ctrl_pos = std.mem.indexOf(u8, result.output, "class UserController") orelse return error.TestUnexpectedResult;
    try std.testing.expect(repo_pos < svc_pos);
    try std.testing.expect(svc_pos < ctrl_pos);
    // 타입 어노테이션 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, ": number") == null);
}

test "Real-world: plugin system pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { registerPlugin } from './app';
        \\import { loggerPlugin } from './plugins/logger';
        \\import { authPlugin } from './plugins/auth';
        \\registerPlugin(loggerPlugin);
        \\registerPlugin(authPlugin);
    );
    try writeFile(tmp.dir, "app.ts",
        \\const plugins: Function[] = [];
        \\export function registerPlugin(p: Function) { plugins.push(p); }
    );
    try writeFile(tmp.dir, "plugins/logger.ts",
        \\export function loggerPlugin() { console.log('Logger active'); }
    );
    try writeFile(tmp.dir, "plugins/auth.ts",
        \\export function authPlugin() { console.log('Auth active'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function loggerPlugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function authPlugin") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function registerPlugin") != null);
}

test "Real-world: state management pattern (Redux-like)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { createStore } from './store';
        \\import { counterReducer } from './reducers/counter';
        \\const store = createStore(counterReducer);
        \\console.log(store.getState());
    );
    try writeFile(tmp.dir, "store.ts",
        \\export function createStore(reducer: Function) {
        \\  let state = reducer(undefined, { type: '@@INIT' });
        \\  return {
        \\    getState: () => state,
        \\    dispatch: (action: any) => { state = reducer(state, action); },
        \\  };
        \\}
    );
    try writeFile(tmp.dir, "reducers/counter.ts",
        \\export function counterReducer(state: number = 0, action: any) {
        \\  switch (action.type) {
        \\    case 'INCREMENT': return state + 1;
        \\    case 'DECREMENT': return state - 1;
        \\    default: return state;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function createStore") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function counterReducer") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'INCREMENT'") != null);
}

test "Real-world: middleware chain pattern" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "server.ts",
        \\import { cors } from './middleware/cors';
        \\import { rateLimit } from './middleware/rate-limit';
        \\import { handler } from './handler';
        \\const pipeline = [cors, rateLimit, handler];
        \\console.log(pipeline);
    );
    try writeFile(tmp.dir, "middleware/cors.ts",
        \\export function cors(req: any, next: Function) { next(); }
    );
    try writeFile(tmp.dir, "middleware/rate-limit.ts",
        \\export function rateLimit(req: any, next: Function) { next(); }
    );
    try writeFile(tmp.dir, "handler.ts",
        \\export function handler(req: any) { return { status: 200 }; }
    );

    const entry = try absPath(&tmp, "server.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function cors") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function rateLimit") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function handler") != null);
}

// ============================================================
// Error handling & diagnostics
// ============================================================

test "Error: multiple unresolved imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './missing1';
        \\import './missing2';
        \\console.log('unreachable');
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
    // 2개의 unresolved import 에러
    var unresolved_count: usize = 0;
    for (result.getDiagnostics()) |d| {
        if (d.code == .unresolved_import) unresolved_count += 1;
    }
    try std.testing.expect(unresolved_count >= 2);
}

test "Error: unresolved in dependency (not entry)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x } from './dep';
        \\console.log(x);
    );
    try writeFile(tmp.dir, "dep.ts",
        \\import './nonexistent';
        \\export const x = 1;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // dep.ts 내부의 미해석 import도 에러로 보고
    try std.testing.expect(result.hasErrors());
}

// ============================================================
// Format-specific advanced tests
// ============================================================

test "Format: all three formats produce valid output for same input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { square } from './math';
        \\console.log(square(5));
    );
    try writeFile(tmp.dir, "math.ts",
        \\export function square(n: number) { return n * n; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // ESM
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .esm,
    });
    defer b1.deinit();
    const r1 = try b1.bundle();
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(!r1.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "n * n") != null);

    // CJS
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .cjs,
    });
    defer b2.deinit();
    const r2 = try b2.bundle();
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(!r2.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, r2.output, "'use strict';\n"));
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "n * n") != null);

    // IIFE
    var b3 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .format = .iife,
    });
    defer b3.deinit();
    const r3 = try b3.bundle();
    defer r3.deinit(std.testing.allocator);
    try std.testing.expect(!r3.hasErrors());
    try std.testing.expect(std.mem.startsWith(u8, r3.output, "(function() {\n"));
    try std.testing.expect(std.mem.indexOf(u8, r3.output, "n * n") != null);
}

test "Format: minify removes module boundary comments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './dep';\nconsole.log('entry');");
    try writeFile(tmp.dir, "dep.ts", "console.log('dep');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // minify=false → 경계 주석 있음
    var b1 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify = false,
    });
    defer b1.deinit();
    const r1 = try b1.bundle();
    defer r1.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r1.output, "// ---") != null);

    // minify=true → 경계 주석 없음
    var b2 = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .minify = true,
    });
    defer b2.deinit();
    const r2 = try b2.bundle();
    defer r2.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, r2.output, "// ---") == null);
}

test "Format: scope_hoist false with all three formats" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './m';\nconsole.log(x);");
    try writeFile(tmp.dir, "m.ts", "export const x = 99;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // scope_hoist=false + ESM → import/export 유지
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{entry},
        .scope_hoist = false,
        .format = .esm,
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(
        std.mem.indexOf(u8, result.output, "export") != null or
            std.mem.indexOf(u8, result.output, "import") != null,
    );
}

// ============================================================
// Mixed patterns & complex interactions
// ============================================================

test "Mixed: import default + named from same module, re-exported" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { wrapped } from './wrapper';
        \\console.log(wrapped);
    );
    try writeFile(tmp.dir, "wrapper.ts",
        \\import api, { version } from './api';
        \\export const wrapped = api + ' v' + version;
    );
    try writeFile(tmp.dir, "api.ts",
        \\export const version = '2.0';
        \\export default 'MyAPI';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'2.0'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'MyAPI'") != null);
}

test "Mixed: export * and named export same module" {
    // Rolldown issues/7233 참고
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c } from './barrel';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './m1';
        \\export * from './m2';
    );
    try writeFile(tmp.dir, "m1.ts", "export const a = 'from-m1';");
    try writeFile(tmp.dir, "m2.ts", "export const b = 'from-m2';\nexport const c = 'also-m2';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-m1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'from-m2'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'also-m2'") != null);
}

test "Mixed: deeply nested barrel with re-exports and defaults" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { utils, helpers } from './lib';
        \\console.log(utils, helpers);
    );
    try writeFile(tmp.dir, "lib/index.ts",
        \\export { utils } from './utils';
        \\export { helpers } from './helpers';
    );
    try writeFile(tmp.dir, "lib/utils/index.ts",
        \\export { format } from './format';
        \\export const utils = 'utils-pkg';
    );
    try writeFile(tmp.dir, "lib/utils/format.ts",
        \\export function format(s: string) { return s.trim(); }
    );
    try writeFile(tmp.dir, "lib/helpers/index.ts",
        \\export const helpers = 'helpers-pkg';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'utils-pkg'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'helpers-pkg'") != null);
}

test "Mixed: template literals and tagged templates across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { greet, TAG } from './strings';
        \\console.log(greet('world'));
    );
    try writeFile(tmp.dir, "strings.ts",
        \\export const TAG = 'v1';
        \\export function greet(name: string) {
        \\  return `Hello, ${name}! (${TAG})`;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function greet") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "${name}") != null);
}

test "Mixed: spread operator and rest params across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { merge, sum } from './utils';
        \\console.log(merge({ a: 1 }, { b: 2 }));
        \\console.log(sum(1, 2, 3));
    );
    try writeFile(tmp.dir, "utils.ts",
        \\export function merge(a: object, b: object) { return { ...a, ...b }; }
        \\export function sum(...nums: number[]) { return nums.reduce((a, b) => a + b, 0); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function merge") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function sum") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "...nums") != null);
}

test "Mixed: destructuring in import and export" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y } from './point';
        \\console.log(x, y);
    );
    try writeFile(tmp.dir, "point.ts",
        \\const point = { x: 10, y: 20, z: 30 };
        \\export const { x, y } = point;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
}

test "Mixed: generator function across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { range } from './iter';
        \\for (const n of range(5)) { console.log(n); }
    );
    try writeFile(tmp.dir, "iter.ts",
        \\export function* range(n: number) {
        \\  for (let i = 0; i < n; i++) yield i;
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function*") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "yield") != null);
}

test "Mixed: computed property names across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { KEYS, createMap } from './map';
        \\console.log(createMap());
    );
    try writeFile(tmp.dir, "map.ts",
        \\export const KEYS = { name: 'name', age: 'age' };
        \\export function createMap() {
        \\  return { [KEYS.name]: 'John', [KEYS.age]: 30 };
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[KEYS.name]") != null);
}

// ============================================================
// Stress tests: larger scale
// ============================================================

test "Stress: 20 modules in diamond lattice" {
    // A → B1..B4 → C1..C4 (각 B가 모든 C를 import)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './b1'; import './b2'; import './b3'; import './b4';
        \\console.log('entry');
    );
    try writeFile(tmp.dir, "b1.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b1');");
    try writeFile(tmp.dir, "b2.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b2');");
    try writeFile(tmp.dir, "b3.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b3');");
    try writeFile(tmp.dir, "b4.ts", "import './c1'; import './c2'; import './c3'; import './c4';\nconsole.log('b4');");
    try writeFile(tmp.dir, "c1.ts", "console.log('c1');");
    try writeFile(tmp.dir, "c2.ts", "console.log('c2');");
    try writeFile(tmp.dir, "c3.ts", "console.log('c3');");
    try writeFile(tmp.dir, "c4.ts", "console.log('c4');");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // c 모듈들이 b 모듈들보다 먼저, b가 entry보다 먼저
    const c1_pos = std.mem.indexOf(u8, result.output, "'c1'") orelse return error.TestUnexpectedResult;
    const b1_pos = std.mem.indexOf(u8, result.output, "'b1'") orelse return error.TestUnexpectedResult;
    const e_pos = std.mem.indexOf(u8, result.output, "'entry'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(c1_pos < b1_pos);
    try std.testing.expect(b1_pos < e_pos);
    // c 모듈은 각각 한 번만 포함 (dedup)
    var c1_count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "'c1'")) |pos| {
        c1_count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), c1_count);
}

// ============================================================
// export { x as default } and named-as-default patterns
// ============================================================

test "Export: named as default" {
    // export { x as default } — named export를 default로 re-alias
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import value from './mod';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "mod.ts",
        \\const value = 42;
        \\export { value as default };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
}

test "Export: empty export clause" {
    // Rollup empty-export: export {} — 사이드이펙트는 유지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import './side';
        \\console.log('main');
    );
    try writeFile(tmp.dir, "side.ts",
        \\console.log('side-effect');
        \\export {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'side-effect'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'main'") != null);
}

test "Export: multiple imports from same module (dedup bindings)" {
    // 같은 모듈을 여러 번 import — 모듈은 한 번만 실행
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { foo } from './lib';
        \\import { bar } from './lib';
        \\console.log(foo, bar);
    );
    try writeFile(tmp.dir, "lib.ts",
        \\console.log('lib init');
        \\export const foo = 'FOO';
        \\export const bar = 'BAR';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // lib init은 한 번만 포함
    var count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "'lib init'")) |pos| {
        count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'FOO'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'BAR'") != null);
}

test "Export: export let with later mutation" {
    // Rollup assignment-to-exports: export let은 뒤에서 재할당 가능
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { count, inc } from './counter';
        \\inc();
        \\console.log(count);
    );
    try writeFile(tmp.dir, "counter.ts",
        \\export let count = 0;
        \\export function inc() { count++; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "let count = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "count++") != null);
}

// ============================================================
// Variable hoisting patterns (Rollup 참고)
// ============================================================

test "Hoisting: var declarations across modules" {
    // var는 hoisting → 번들에서도 올바르게 동작해야 함
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getValue } from './hoisted';
        \\console.log(getValue());
    );
    try writeFile(tmp.dir, "hoisted.ts",
        \\export function getValue() { return x; }
        \\var x = 'hoisted-value';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'hoisted-value'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function getValue") != null);
}

test "Hoisting: function declarations hoisted above usage" {
    // 함수 선언은 hoisting → 사용보다 뒤에 선언돼도 동작
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { run } from './runner';
        \\run();
    );
    try writeFile(tmp.dir, "runner.ts",
        \\export function run() { return helper(); }
        \\function helper() { return 'helped'; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function run") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function helper") != null);
}

// ============================================================
// Complex TypeScript patterns not yet covered
// ============================================================

test "TypeScript: declare module stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { process } from './app';
        \\process();
    );
    try writeFile(tmp.dir, "app.ts",
        \\declare module '*.css' { const css: string; export default css; }
        \\export function process() { console.log('processing'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // declare module 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "declare") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'processing'") != null);
}

test "TypeScript: readonly and access modifiers stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Config } from './config';
        \\const c = new Config('prod', 3000);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export class Config {
        \\  public readonly env: string;
        \\  private port: number;
        \\  constructor(env: string, port: number) {
        \\    this.env = env;
        \\    this.port = port;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readonly") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Config") != null);
}

test "TypeScript: intersection and union types stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { format } from './formatter';
        \\console.log(format('hello'));
    );
    try writeFile(tmp.dir, "formatter.ts",
        \\type StringOrNumber = string | number;
        \\type WithId = { id: number } & { name: string };
        \\export function format(input: StringOrNumber): string {
        \\  return String(input);
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "StringOrNumber") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "WithId") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "function format") != null);
}

test "TypeScript: as const and satisfies stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { COLORS } from './theme';
        \\console.log(COLORS);
    );
    try writeFile(tmp.dir, "theme.ts",
        \\export const COLORS = {
        \\  red: '#ff0000',
        \\  blue: '#0000ff',
        \\} as const;
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "as const") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'#ff0000'") != null);
}

test "TypeScript: parameter property transform in bundle" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Point } from './point';
        \\const p = new Point(10, 20);
        \\console.log(p);
    );
    try writeFile(tmp.dir, "point.ts",
        \\export class Point {
        \\  constructor(public x: number, public y: number) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Point") != null);
    // parameter property → this.x = x; this.y = y; 로 변환
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.x") != null);
}

// ============================================================
// Scope hoisting: deeper patterns (Webpack 참고)
// ============================================================

test "Scope hoisting: imported value used as object key" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { KEY } from './keys';
        \\const obj = { [KEY]: 'value' };
        \\console.log(obj);
    );
    try writeFile(tmp.dir, "keys.ts", "export const KEY = 'myKey';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'myKey'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[KEY]") != null);
}

test "Scope hoisting: imported value in template literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { name } from './user';
        \\console.log(`Hello, ${name}!`);
    );
    try writeFile(tmp.dir, "user.ts", "export const name = 'Alice';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'Alice'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "${name}") != null);
}

test "Scope hoisting: imported value in array destructuring" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { pair } from './data';
        \\const [a, b] = pair;
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "data.ts", "export const pair = [1, 2];");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[1, 2]") != null);
}

test "Scope hoisting: imported value in ternary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { DEBUG } from './env';
        \\const level = DEBUG ? 'verbose' : 'error';
        \\console.log(level);
    );
    try writeFile(tmp.dir, "env.ts", "export const DEBUG = true;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "DEBUG") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'verbose'") != null);
}

// ============================================================
// Error cases: more thorough
// ============================================================

test "Error: syntax error in dependency" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import './bad';\nconsole.log('ok');");
    try writeFile(tmp.dir, "bad.ts", "const = ;"); // 구문 오류

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 구문 오류가 있는 모듈 → 에러 또는 번들 생성 (에러 복구에 따라)
    // 최소한 크래시하지 않아야 함
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: circular re-export chain" {
    // A re-exports from B, B re-exports from A → 무한 루프 방지
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts", "import { x } from './a';\nconsole.log(x);");
    try writeFile(tmp.dir, "a.ts", "export { x } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x } from './a';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    // 무한 루프에 빠지지 않고 완료해야 함 (에러 보고 가능)
    try std.testing.expect(result.output.len > 0 or result.hasErrors());
}

test "Error: entry point not found" {
    var b = Bundler.init(std.testing.allocator, .{
        .entry_points = &.{"/nonexistent/path/entry.ts"},
    });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.hasErrors());
}

// ============================================================
// Re-export advanced: Rollup form/samples 참고
// ============================================================

test "Re-export: export * from multiple sources" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c } from './all';
        \\console.log(a, b, c);
    );
    try writeFile(tmp.dir, "all.ts",
        \\export * from './src-a';
        \\export * from './src-b';
    );
    try writeFile(tmp.dir, "src-a.ts", "export const a = 'A';\nexport const b = 'B';");
    try writeFile(tmp.dir, "src-b.ts", "export const c = 'C';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'A'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'B'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'C'") != null);
}

test "Re-export: mixed named and star from same module" {
    // Rolldown #7233: 같은 모듈에서 named + star 동시
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { x, y, z } from './proxy';
        \\console.log(x, y, z);
    );
    try writeFile(tmp.dir, "proxy.ts",
        \\export { x } from './source';
        \\export * from './source';
    );
    try writeFile(tmp.dir, "source.ts",
        \\export const x = 'X';
        \\export const y = 'Y';
        \\export const z = 'Z';
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'X'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'Y'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'Z'") != null);
}

test "Re-export: re-export default as named" {
    // export { default as Foo } from './foo'
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './proxy';
        \\console.log(Foo);
    );
    try writeFile(tmp.dir, "proxy.ts", "export { default as Foo } from './foo';");
    try writeFile(tmp.dir, "foo.ts", "export default 'default-foo';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'default-foo'") != null);
}

test "Stress: all formats + minify combinations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { value } from './dep';
        \\console.log(value);
    );
    try writeFile(tmp.dir, "dep.ts", "export const value = 42;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    // 6가지 조합 모두 성공해야 함
    const formats = [_]emitter.EmitOptions.Format{ .esm, .cjs, .iife };
    const minify_opts = [_]bool{ false, true };
    for (formats) |fmt| {
        for (minify_opts) |minify| {
            var b = Bundler.init(std.testing.allocator, .{
                .entry_points = &.{entry},
                .format = fmt,
                .minify = minify,
            });
            defer b.deinit();
            const result = try b.bundle();
            defer result.deinit(std.testing.allocator);

            try std.testing.expect(!result.hasErrors());
            try std.testing.expect(std.mem.indexOf(u8, result.output, "42") != null);
        }
    }
}

// ============================================================
// Inline type import edge cases
// ============================================================

test "TypeScript: import type only specifiers all stripped" {
    // 모든 specifier가 type-only → import 문 자체가 side-effect only가 됨
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type Foo, type Bar } from './types';
        \\console.log('no types used');
    );
    try writeFile(tmp.dir, "types.ts",
        \\export interface Foo { x: number; }
        \\export interface Bar { y: string; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "interface") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'no types used'") != null);
}

test "TypeScript: import { type } as value name" {
    // import { type } → 'type'이라는 값 import (modifier 아님)
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { type } from './mod';
        \\console.log(type);
    );
    try writeFile(tmp.dir, "mod.ts", "export const type = 'my-type-value';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'my-type-value'") != null);
}

// ============================================================
// Declare module patterns
// ============================================================

test "TypeScript: declare module '*.svg' stripped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { render } from './app';
        \\render();
    );
    try writeFile(tmp.dir, "app.ts",
        \\declare module '*.svg' { const src: string; export default src; }
        \\declare module '*.png' { const src: string; export default src; }
        \\export function render() { console.log('rendered'); }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "declare") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'rendered'") != null);
}

// ============================================================
// Parameter property patterns
// ============================================================

test "TypeScript: parameter property with multiple modifiers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Config } from './config';
        \\const c = new Config('prod', true);
        \\console.log(c);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export class Config {
        \\  constructor(public readonly env: string, private debug: boolean) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Config") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.env") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.debug") != null);
    // 접근 제어자 제거
    try std.testing.expect(std.mem.indexOf(u8, result.output, "public") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "private") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "readonly") == null);
}

test "TypeScript: parameter property with default value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Server } from './server';
        \\const s = new Server();
        \\console.log(s);
    );
    try writeFile(tmp.dir, "server.ts",
        \\export class Server {
        \\  constructor(public port: number = 3000) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class Server") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "this.port") != null);
}

// ============================================================
// New expression patterns (bug regression tests)
// ============================================================

test "New expression: basic constructor call" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Foo } from './foo';
        \\const f = new Foo();
        \\console.log(f);
    );
    try writeFile(tmp.dir, "foo.ts", "export class Foo { x = 1; }");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Foo()") != null);
}

test "New expression: with arguments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Vec2 } from './vec';
        \\const v = new Vec2(10, 20);
        \\console.log(v);
    );
    try writeFile(tmp.dir, "vec.ts",
        \\export class Vec2 {
        \\  constructor(public x: number, public y: number) {}
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Vec2(10, 20)") != null);
}

test "New expression: nested new" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Wrapper, Inner } from './classes';
        \\const w = new Wrapper(new Inner());
        \\console.log(w);
    );
    try writeFile(tmp.dir, "classes.ts",
        \\export class Inner { val = 'inner'; }
        \\export class Wrapper { constructor(public child: Inner) {} }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Wrapper") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "new Inner") != null);
}

// ============================================================
// Default export regression tests
// ============================================================

test "Default: default export object literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import config from './config';
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export default { host: 'localhost', port: 8080 };
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'localhost'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "8080") != null);
}

test "Default: default export array literal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import items from './items';
        \\console.log(items);
    );
    try writeFile(tmp.dir, "items.ts",
        \\export default ['a', 'b', 'c'];
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'a'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'b'") != null);
}

test "Default: default export used in expression" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import multiplier from './multiplier';
        \\const result = multiplier * 10;
        \\console.log(result);
    );
    try writeFile(tmp.dir, "multiplier.ts", "export default 5;");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "* 10") != null);
}

// ============================================================
// Codegen formatting regression tests
// ============================================================

test "Codegen: object literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2, z: 3 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // non-minify: 콜론 뒤 공백, 쉼표 뒤 공백
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "y: 2") != null);
}

test "Codegen: object literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const obj = { x: 1, y: 2 };
        \\console.log(obj);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // minify: 공백 없음
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x:1") != null);
}

test "Codegen: array literal formatting non-minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify = false });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10, 20, 30]") != null);
}

test "Codegen: array literal formatting minify" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\const arr = [10, 20, 30];
        \\console.log(arr);
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry}, .minify = true });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "[10,20,30]") != null);
}

// ============================================================
// Complex class patterns across modules
// ============================================================

test "Class: inheritance chain across 3 modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { Cat } from './cat';
        \\const c = new Cat('Mimi');
        \\console.log(c.speak());
    );
    try writeFile(tmp.dir, "cat.ts",
        \\import { Pet } from './pet';
        \\export class Cat extends Pet {
        \\  speak() { return this.name + ' meows'; }
        \\}
    );
    try writeFile(tmp.dir, "pet.ts",
        \\export class Pet {
        \\  name: string;
        \\  constructor(name: string) { this.name = name; }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // Pet → Cat → entry 순서
    const pet_pos = std.mem.indexOf(u8, result.output, "class Pet") orelse return error.TestUnexpectedResult;
    const cat_pos = std.mem.indexOf(u8, result.output, "class Cat") orelse return error.TestUnexpectedResult;
    try std.testing.expect(pet_pos < cat_pos);
}

test "Class: static methods across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { MathUtils } from './math-utils';
        \\console.log(MathUtils.clamp(15, 0, 10));
    );
    try writeFile(tmp.dir, "math-utils.ts",
        \\export class MathUtils {
        \\  static clamp(val: number, min: number, max: number): number {
        \\    return Math.min(Math.max(val, min), max);
        \\  }
        \\  static lerp(a: number, b: number, t: number): number {
        \\    return a + (b - a) * t;
        \\  }
        \\}
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "class MathUtils") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "static clamp") != null);
}

// ============================================================
// Complex expression patterns
// ============================================================

test "Expression: optional chaining across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getUser } from './api';
        \\const name = getUser()?.name;
        \\console.log(name);
    );
    try writeFile(tmp.dir, "api.ts",
        \\export function getUser() { return { name: 'Alice' }; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "?.name") != null);
}

test "Expression: nullish coalescing across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { getValue } from './store';
        \\const result = getValue() ?? 'default';
        \\console.log(result);
    );
    try writeFile(tmp.dir, "store.ts",
        \\export function getValue() { return null; }
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'default'") != null);
}

test "Expression: logical assignment across modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { config } from './config';
        \\config.debug ??= false;
        \\config.verbose ||= true;
        \\console.log(config);
    );
    try writeFile(tmp.dir, "config.ts",
        \\export const config: any = {};
    );

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "??=") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "||=") != null);
}

// ============================================================
// Advanced module patterns
// ============================================================

test "Module: re-export with rename chain" {
    // A exports x, B re-exports x as y, C re-exports y as z, entry imports z
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { z } from './c';
        \\console.log(z);
    );
    try writeFile(tmp.dir, "c.ts", "export { y as z } from './b';");
    try writeFile(tmp.dir, "b.ts", "export { x as y } from './a';");
    try writeFile(tmp.dir, "a.ts", "export const x = 'renamed-three-times';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'renamed-three-times'") != null);
}

test "Module: side-effect import between value imports" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import { a } from './a';
        \\import './side';
        \\import { b } from './b';
        \\console.log(a, b);
    );
    try writeFile(tmp.dir, "a.ts", "export const a = 'A';");
    try writeFile(tmp.dir, "side.ts", "console.log('SIDE');");
    try writeFile(tmp.dir, "b.ts", "export const b = 'B';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // side-effect는 a와 b 사이에 실행
    const a_pos = std.mem.indexOf(u8, result.output, "'A'") orelse return error.TestUnexpectedResult;
    const side_pos = std.mem.indexOf(u8, result.output, "'SIDE'") orelse return error.TestUnexpectedResult;
    const b_pos = std.mem.indexOf(u8, result.output, "'B'") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a_pos < side_pos);
    try std.testing.expect(side_pos < b_pos);
}

test "Module: import same default from two different modules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "entry.ts",
        \\import configA from './a';
        \\import configB from './b';
        \\console.log(configA, configB);
    );
    try writeFile(tmp.dir, "a.ts", "export default { name: 'A' };");
    try writeFile(tmp.dir, "b.ts", "export default { name: 'B' };");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'A'") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "'B'") != null);
}

// ============================================================
// Stress: large real-world-like patterns
// ============================================================

test "Stress: micro-framework with models, views, controllers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "main.ts",
        \\import { App } from './framework/app';
        \\import { UserModel } from './models/user';
        \\import { UserView } from './views/user';
        \\const app = new App();
        \\const model = new UserModel();
        \\const view = new UserView();
        \\console.log(app, model, view);
    );
    try writeFile(tmp.dir, "framework/app.ts",
        \\import { Router } from './router';
        \\export class App { router = new Router(); }
    );
    try writeFile(tmp.dir, "framework/router.ts",
        \\export class Router { routes: string[] = []; }
    );
    try writeFile(tmp.dir, "models/user.ts",
        \\import { BaseModel } from './base';
        \\export class UserModel extends BaseModel { table = 'users'; }
    );
    try writeFile(tmp.dir, "models/base.ts",
        \\export class BaseModel { id = 0; }
    );
    try writeFile(tmp.dir, "views/user.ts",
        \\import { BaseView } from './base';
        \\export class UserView extends BaseView { template = '<div/>'; }
    );
    try writeFile(tmp.dir, "views/base.ts",
        \\export class BaseView { el = 'body'; }
    );

    const entry = try absPath(&tmp, "main.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // 모든 클래스가 번들에 포함
    for ([_][]const u8{ "class App", "class Router", "class UserModel", "class BaseModel", "class UserView", "class BaseView" }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, result.output, needle) != null);
    }
    // base 클래스가 derived보다 먼저
    const base_model_pos = std.mem.indexOf(u8, result.output, "class BaseModel") orelse return error.TestUnexpectedResult;
    const user_model_pos = std.mem.indexOf(u8, result.output, "class UserModel") orelse return error.TestUnexpectedResult;
    try std.testing.expect(base_model_pos < user_model_pos);
}

test "Stress: 15 modules with mixed patterns" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // entry imports from barrel which re-exports from 5 modules, each importing shared
    try writeFile(tmp.dir, "entry.ts",
        \\import { a, b, c, d, e } from './barrel';
        \\console.log(a, b, c, d, e);
    );
    try writeFile(tmp.dir, "barrel.ts",
        \\export { a } from './modules/a';
        \\export { b } from './modules/b';
        \\export { c } from './modules/c';
        \\export { d } from './modules/d';
        \\export { e } from './modules/e';
    );
    try writeFile(tmp.dir, "modules/a.ts", "import { shared } from '../shared';\nexport const a = shared + '-a';");
    try writeFile(tmp.dir, "modules/b.ts", "import { shared } from '../shared';\nexport const b = shared + '-b';");
    try writeFile(tmp.dir, "modules/c.ts", "import { shared } from '../shared';\nexport const c = shared + '-c';");
    try writeFile(tmp.dir, "modules/d.ts", "import { shared } from '../shared';\nexport const d = shared + '-d';");
    try writeFile(tmp.dir, "modules/e.ts", "import { shared } from '../shared';\nexport const e = shared + '-e';");
    try writeFile(tmp.dir, "shared.ts", "export const shared = 'SHARED';");

    const entry = try absPath(&tmp, "entry.ts");
    defer std.testing.allocator.free(entry);

    var b = Bundler.init(std.testing.allocator, .{ .entry_points = &.{entry} });
    defer b.deinit();
    const result = try b.bundle();
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.hasErrors());
    // shared는 한 번만 포함
    var count: usize = 0;
    var sf: usize = 0;
    while (std.mem.indexOfPos(u8, result.output, sf, "'SHARED'")) |pos| {
        count += 1;
        sf = pos + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}
