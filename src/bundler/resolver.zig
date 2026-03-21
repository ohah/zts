//! ZTS Bundler — Module Resolver
//!
//! import 경로를 절대 파일 경로로 해석한다 (D081 Layer 1).
//! 상대 경로(`./`, `../`)와 절대 경로를 처리.
//! bare specifier (node_modules)는 PR #4에서 추가.
//!
//! 해석 알고리즘 (D064):
//!   1. 경로 조합 (source_dir + specifier)
//!   2. 정확한 파일 존재 확인
//!   3. 확장자 추가: .ts, .tsx, .js, .jsx, .json
//!   4. TS 확장자 매핑: .js → .ts/.tsx (Rolldown 방식)
//!   5. 디렉토리 index: dir/index.ts, dir/index.tsx, dir/index.js
//!   6. 없으면 ModuleNotFound
//!
//! 참고:
//!   - references/esbuild/internal/resolver/resolver.go
//!   - references/rolldown/crates/rolldown_resolver/src/resolver.rs
//!   - references/bun/src/resolver/resolver.zig

const std = @import("std");
const types = @import("types.zig");
const ModuleType = types.ModuleType;

pub const ResolveResult = struct {
    /// 해석된 절대 파일 경로
    path: []const u8,
    /// 확장자에서 추론한 모듈 타입
    module_type: ModuleType,
};

pub const ResolveError = error{
    ModuleNotFound,
    OutOfMemory,
};

/// 기본 확장자 탐색 순서.
/// TypeScript 확장자가 먼저 (TS 프로젝트에서 .ts가 .js보다 우선).
const default_extensions: []const []const u8 = &.{ ".ts", ".tsx", ".js", ".jsx", ".json" };

/// TS 확장자 매핑 (D064).
/// import './foo.js'가 실제로 ./foo.ts를 가리킬 수 있음.
const ts_extension_map: []const struct { from: []const u8, to: []const []const u8 } = &.{
    .{ .from = ".js", .to = &.{ ".ts", ".tsx" } },
    .{ .from = ".jsx", .to = &.{".tsx"} },
    .{ .from = ".mjs", .to = &.{".mts"} },
    .{ .from = ".cjs", .to = &.{".cts"} },
};

/// index 파일 탐색 순서 (디렉토리 해석 시).
const index_files: []const []const u8 = &.{ "index.ts", "index.tsx", "index.js", "index.jsx" };

pub const Resolver = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    /// 상대/절대 경로를 해석하여 절대 파일 경로를 반환한다.
    /// source_dir: 가져오는(importing) 파일이 있는 디렉토리의 절대 경로
    /// specifier: import 경로 (예: "./foo", "../bar", "/abs/path")
    pub fn resolve(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // bare specifier는 이 PR에서 미지원 (PR #4에서 추가)
        if (!isRelativeOrAbsolute(specifier)) {
            return error.ModuleNotFound;
        }

        // 경로 조합
        const joined = std.fs.path.resolve(self.allocator, &.{ source_dir, specifier }) catch
            return error.OutOfMemory;
        defer self.allocator.free(joined);

        // 1. 정확한 경로가 파일로 존재하는지
        if (self.fileExists(joined)) {
            return (try self.makeResult(joined)).?;
        }

        // 2. 확장자 추가 탐색 (.ts, .tsx, .js, .jsx, .json)
        if (try self.tryExtensions(joined)) |result| {
            return result;
        }

        // 3. TS 확장자 매핑 (./foo.js → ./foo.ts, ./foo.tsx)
        if (try self.tryTsExtensionMapping(joined)) |result| {
            return result;
        }

        // 4. 디렉토리 index 탐색 (./dir → ./dir/index.ts)
        if (try self.tryDirectoryIndex(joined)) |result| {
            return result;
        }

        return error.ModuleNotFound;
    }

    /// 확장자를 하나씩 붙여서 존재하는 파일을 찾는다.
    fn tryExtensions(self: *Resolver, base: []const u8) ResolveError!?ResolveResult {
        for (default_extensions) |ext| {
            const path = std.mem.concat(self.allocator, u8, &.{ base, ext }) catch
                return error.OutOfMemory;
            defer self.allocator.free(path);

            if (self.fileExists(path)) {
                return self.makeResult(path);
            }
        }
        return null;
    }

    /// TS 확장자 매핑: .js → .ts/.tsx 등.
    /// import './foo.js' 했는데 foo.js는 없고 foo.ts가 있으면 foo.ts로 해석.
    fn tryTsExtensionMapping(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        const ext = std.fs.path.extension(path);
        for (ts_extension_map) |mapping| {
            if (std.mem.eql(u8, ext, mapping.from)) {
                // 확장자를 벗기고 대체 확장자를 붙임
                const base = path[0 .. path.len - ext.len];
                for (mapping.to) |to_ext| {
                    const mapped = std.mem.concat(self.allocator, u8, &.{ base, to_ext }) catch
                        return error.OutOfMemory;
                    defer self.allocator.free(mapped);

                    if (self.fileExists(mapped)) {
                        return self.makeResult(mapped);
                    }
                }
                break;
            }
        }
        return null;
    }

    /// 디렉토리인 경우 index 파일을 탐색한다.
    fn tryDirectoryIndex(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        // path가 디렉토리인지 확인
        if (!self.dirExists(path)) return null;

        for (index_files) |index_name| {
            const index_path = std.fs.path.resolve(self.allocator, &.{ path, index_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(index_path);

            if (self.fileExists(index_path)) {
                return self.makeResult(index_path);
            }
        }
        return null;
    }

    fn makeResult(self: *Resolver, path: []const u8) ResolveError!?ResolveResult {
        const ext = std.fs.path.extension(path);
        return .{
            .path = self.allocator.dupe(u8, path) catch return error.OutOfMemory,
            .module_type = ModuleType.fromExtension(ext),
        };
    }

    fn fileExists(_: *const Resolver, path: []const u8) bool {
        const stat = std.fs.cwd().statFile(path) catch return false;
        return stat.kind == .file;
    }

    fn dirExists(_: *const Resolver, path: []const u8) bool {
        var dir = std.fs.cwd().openDir(path, .{}) catch return false;
        dir.close();
        return true;
    }
};

/// specifier가 상대 경로(`./`, `../`) 또는 절대 경로(`/`)인지 판별.
pub fn isRelativeOrAbsolute(specifier: []const u8) bool {
    if (specifier.len == 0) return false;
    if (specifier[0] == '/') return true;
    if (specifier.len >= 2 and specifier[0] == '.' and (specifier[1] == '/' or specifier[1] == '.')) return true;
    return false;
}

// ============================================================
// Tests
// ============================================================

test "isRelativeOrAbsolute" {
    try std.testing.expect(isRelativeOrAbsolute("./foo"));
    try std.testing.expect(isRelativeOrAbsolute("../foo"));
    try std.testing.expect(isRelativeOrAbsolute("/abs/path"));
    try std.testing.expect(!isRelativeOrAbsolute("react"));
    try std.testing.expect(!isRelativeOrAbsolute("@mui/material"));
    try std.testing.expect(!isRelativeOrAbsolute(""));
}

/// 테스트용 헬퍼: tmpDir에 파일 생성
fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

test "resolve: exact file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "foo.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./foo.ts");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "foo.ts"));
    try std.testing.expectEqual(ModuleType.javascript, result.module_type);
}

test "resolve: extension search (.ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "bar.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./bar");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "bar.ts"));
}

test "resolve: extension search (.tsx before .js)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "comp.tsx");
    try createFile(tmp.dir, "comp.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./comp");
    defer std.testing.allocator.free(result.path);

    // .ts → .tsx → .js 순서이므로 .tsx가 먼저
    try std.testing.expect(std.mem.endsWith(u8, result.path, "comp.tsx"));
}

test "resolve: TS extension mapping (.js → .ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "util.ts");
    // util.js는 없음. import './util.js' → ./util.ts로 해석

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./util.js");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "util.ts"));
}

test "resolve: TS extension mapping (.jsx → .tsx)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "App.tsx");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./App.jsx");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "App.tsx"));
}

test "resolve: directory index (./dir → ./dir/index.ts)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "components/index.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./components");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "components/index.ts"));
}

test "resolve: directory index (.tsx)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "pages/index.tsx");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./pages");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "pages/index.tsx"));
}

test "resolve: parent directory (../)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "shared.ts");
    try createFile(tmp.dir, "sub/entry.ts");

    const sub_path = try tmp.dir.realpathAlloc(std.testing.allocator, "sub");
    defer std.testing.allocator.free(sub_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(sub_path, "../shared");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(std.mem.endsWith(u8, result.path, "shared.ts"));
}

test "resolve: module not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "./nonexistent");
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "resolve: bare specifier returns ModuleNotFound (PR #4)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "react");
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "resolve: json module type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "data.json");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./data.json");
    defer std.testing.allocator.free(result.path);

    try std.testing.expectEqual(ModuleType.json, result.module_type);
}

test "resolve: css module type" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "style.css");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./style.css");
    defer std.testing.allocator.free(result.path);

    try std.testing.expectEqual(ModuleType.css, result.module_type);
}

test "resolve: extension search priority (.ts > .tsx > .js)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "mod.ts");
    try createFile(tmp.dir, "mod.tsx");
    try createFile(tmp.dir, "mod.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./mod");
    defer std.testing.allocator.free(result.path);

    // .ts가 가장 먼저
    try std.testing.expect(std.mem.endsWith(u8, result.path, "mod.ts"));
}

test "resolve: exact .js file exists (no TS mapping)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "lib.js");
    try createFile(tmp.dir, "lib.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./lib.js");
    defer std.testing.allocator.free(result.path);

    // 정확한 .js가 있으면 TS 매핑하지 않음
    try std.testing.expect(std.mem.endsWith(u8, result.path, "lib.js"));
}
