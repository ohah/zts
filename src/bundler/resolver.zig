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
const pkg_json = @import("package_json.zig");
const PackageJson = pkg_json.PackageJson;

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
/// .mts/.cts는 ESM/CJS 모듈 전용 TypeScript 확장자.
const default_extensions: []const []const u8 = &.{ ".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs", ".json" };

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
    /// 조건 세트 (D064: import kind별로 다를 수 있음).
    /// 기본값은 ESM 브라우저용.
    conditions: []const []const u8 = &.{ "import", "module", "browser", "default" },

    pub fn init(allocator: std.mem.Allocator) Resolver {
        return .{ .allocator = allocator };
    }

    pub fn resolve(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // bare specifier → node_modules 탐색
        if (!isRelativeOrAbsolute(specifier)) {
            return self.resolveNodeModules(source_dir, specifier);
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

    /// bare specifier를 node_modules에서 탐색한다.
    /// source_dir에서 시작하여 상위 디렉토리로 올라가며 node_modules/<pkg>를 찾는다.
    fn resolveNodeModules(self: *Resolver, source_dir: []const u8, specifier: []const u8) ResolveError!ResolveResult {
        // 패키지 이름과 서브패스 분리: "@scope/pkg/utils" → ("@scope/pkg", "./utils")
        const split = splitBareSpecifier(specifier);
        const pkg_name = split.pkg_name;
        const subpath = split.subpath;

        // 상위 디렉토리로 올라가며 node_modules 탐색
        var current_dir = source_dir;
        while (true) {
            // node_modules/<pkg>/package.json 시도
            const pkg_dir_path = std.fs.path.resolve(self.allocator, &.{ current_dir, "node_modules", pkg_name }) catch
                return error.OutOfMemory;
            defer self.allocator.free(pkg_dir_path);

            if (self.dirExists(pkg_dir_path)) {
                if (try self.resolvePackage(pkg_dir_path, subpath)) |result| {
                    return result;
                }
            }

            // 상위 디렉토리로 이동
            const parent = std.fs.path.dirname(current_dir) orelse break;
            if (std.mem.eql(u8, parent, current_dir)) break; // 루트 도달
            current_dir = parent;
        }

        return error.ModuleNotFound;
    }

    /// 패키지 디렉토리에서 엔트리포인트를 해석한다.
    /// 우선순위: exports → module → main → index 파일
    fn resolvePackage(self: *Resolver, pkg_dir_path: []const u8, subpath: []const u8) ResolveError!?ResolveResult {
        var pkg_dir = std.fs.cwd().openDir(pkg_dir_path, .{}) catch return null;
        defer pkg_dir.close();

        // package.json 파싱 시도
        var parsed = pkg_json.parsePackageJson(self.allocator, pkg_dir) catch |err| switch (err) {
            error.FileNotFound => {
                // package.json 없으면 index 파일 탐색
                return self.tryDirectoryIndex(pkg_dir_path);
            },
            else => return null,
        };
        defer parsed.deinit();

        const pkg = &parsed.pkg;

        // 1. exports 필드 (D064)
        // subpath: "." (루트) 또는 "sub" (상대) → exports 매칭용 "." 또는 "./sub"
        const allocated_subpath: ?[]const u8 = if (std.mem.eql(u8, subpath, "."))
            null
        else
            std.mem.concat(self.allocator, u8, &.{ "./", subpath }) catch return error.OutOfMemory;
        defer if (allocated_subpath) |buf| self.allocator.free(buf);
        const exports_subpath = allocated_subpath orelse subpath;

        if (pkg.exports) |exports| {
            if (pkg_json.resolveExports(self.allocator, exports, exports_subpath, self.conditions)) |exports_result| {
                defer if (exports_result.allocated) self.allocator.free(exports_result.path);
                const abs_path = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, exports_result.path }) catch
                    return error.OutOfMemory;
                defer self.allocator.free(abs_path);

                if (self.fileExists(abs_path)) {
                    return self.makeResult(abs_path);
                }
                // exports가 가리키는 파일이 없으면 확장자 탐색
                if (try self.tryExtensions(abs_path)) |result| return result;
            }
            // exports가 있는데 매칭 안 되면 다른 필드로 폴백하지 않음 (Node.js 스펙)
            if (!std.mem.eql(u8, subpath, ".")) return null;
        }

        // 서브패스가 있으면 패키지 내부 파일 직접 해석
        if (!std.mem.eql(u8, subpath, ".")) {
            const sub_file = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, subpath }) catch
                return error.OutOfMemory;
            defer self.allocator.free(sub_file);

            if (self.fileExists(sub_file)) return self.makeResult(sub_file);
            if (try self.tryExtensions(sub_file)) |result| return result;
            if (try self.tryTsExtensionMapping(sub_file)) |result| return result;
            if (try self.tryDirectoryIndex(sub_file)) |result| return result;
            return null;
        }

        // 2. module 필드 (ESM 엔트리, exports 없을 때)
        if (pkg.module) |mod| {
            const abs_path = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, mod }) catch
                return error.OutOfMemory;
            defer self.allocator.free(abs_path);
            if (self.fileExists(abs_path)) return self.makeResult(abs_path);
        }

        // 3. main 필드 (CJS 엔트리)
        if (pkg.main) |main| {
            const abs_path = std.fs.path.resolve(self.allocator, &.{ pkg_dir_path, main }) catch
                return error.OutOfMemory;
            defer self.allocator.free(abs_path);
            if (self.fileExists(abs_path)) return self.makeResult(abs_path);
            // main에 확장자가 없을 수 있음
            if (try self.tryExtensions(abs_path)) |result| return result;
        }

        // 4. index 파일 폴백
        return self.tryDirectoryIndex(pkg_dir_path);
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
    // "./" — 현재 디렉토리 상대
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '/') return true;
    // "../" — 상위 디렉토리 상대. ".." 뒤에 / 또는 끝이어야 함 ("..foo"는 bare specifier)
    if (specifier.len >= 2 and specifier[0] == '.' and specifier[1] == '.') {
        if (specifier.len == 2) return true; // ".." 그 자체
        if (specifier[2] == '/') return true; // "../..."
    }
    return false;
}

/// bare specifier를 패키지 이름과 서브패스로 분리한다.
/// "react" → ("react", ".")
/// "react/jsx-runtime" → ("react", "./jsx-runtime")
/// "@mui/material" → ("@mui/material", ".")
/// "@mui/material/Button" → ("@mui/material", "./Button")
const BareSpecifierSplit = struct {
    pkg_name: []const u8,
    subpath: []const u8,
};

pub fn splitBareSpecifier(specifier: []const u8) BareSpecifierSplit {
    if (specifier.len == 0) return .{ .pkg_name = specifier, .subpath = "." };

    // scoped package: @scope/name/subpath
    if (specifier[0] == '@') {
        if (std.mem.indexOfScalar(u8, specifier, '/')) |first_slash| {
            // 두 번째 / 를 찾으면 그 뒤가 서브패스
            if (std.mem.indexOfScalarPos(u8, specifier, first_slash + 1, '/')) |second_slash| {
                return .{
                    .pkg_name = specifier[0..second_slash],
                    .subpath = specifier[second_slash + 1 ..],
                };
            }
        }
        return .{ .pkg_name = specifier, .subpath = "." };
    }

    // 일반 패키지: name/subpath
    if (std.mem.indexOfScalar(u8, specifier, '/')) |slash| {
        return .{
            .pkg_name = specifier[0..slash],
            .subpath = specifier[slash + 1 ..],
        };
    }

    return .{ .pkg_name = specifier, .subpath = "." };
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

/// 테스트용 헬퍼: tmpDir에 파일 생성 (부모 디렉토리 자동 생성)
fn createFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        dir.makePath(parent) catch {};
    }
    const file = try dir.createFile(path, .{});
    file.close();
}

/// 테스트용 헬퍼: 경로 끝 부분 비교 (구분자 독립 — Windows `\` + Unix `/` 모두 처리).
fn pathEndsWith(path: []const u8, expected_suffix: []const u8) bool {
    if (path.len < expected_suffix.len) return false;
    const tail = path[path.len - expected_suffix.len ..];
    for (tail, expected_suffix) |a, b| {
        const na = if (a == '\\') @as(u8, '/') else a;
        const nb = if (b == '\\') @as(u8, '/') else b;
        if (na != nb) return false;
    }
    return true;
}

const writeFile = @import("test_helpers.zig").writeFile;

test "resolve: exact file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try createFile(tmp.dir, "foo.ts");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "./foo.ts");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "foo.ts"));
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

    try std.testing.expect(pathEndsWith(result.path, "bar.ts"));
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
    try std.testing.expect(pathEndsWith(result.path, "comp.tsx"));
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

    try std.testing.expect(pathEndsWith(result.path, "util.ts"));
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

    try std.testing.expect(pathEndsWith(result.path, "App.tsx"));
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

    try std.testing.expect(pathEndsWith(result.path, "components/index.ts"));
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

    try std.testing.expect(pathEndsWith(result.path, "pages/index.tsx"));
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

    try std.testing.expect(pathEndsWith(result.path, "shared.ts"));
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

test "resolve: bare specifier with main field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/my-lib/package.json", "{\"main\":\"./lib/index.js\"}");
    try createFile(tmp.dir, "node_modules/my-lib/lib/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "my-lib");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "my-lib/lib/index.js"));
}

test "resolve: bare specifier with module field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/esm-pkg/package.json", "{\"module\":\"./esm/index.js\",\"main\":\"./cjs/index.js\"}");
    try createFile(tmp.dir, "node_modules/esm-pkg/esm/index.js");
    try createFile(tmp.dir, "node_modules/esm-pkg/cjs/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "esm-pkg");
    defer std.testing.allocator.free(result.path);

    // module 필드가 main보다 우선
    try std.testing.expect(pathEndsWith(result.path, "esm-pkg/esm/index.js"));
}

test "resolve: bare specifier with exports field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/exp-pkg/package.json", "{\"exports\":{\"import\":\"./esm.js\",\"require\":\"./cjs.js\"}}");
    try createFile(tmp.dir, "node_modules/exp-pkg/esm.js");
    try createFile(tmp.dir, "node_modules/exp-pkg/cjs.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "exp-pkg");
    defer std.testing.allocator.free(result.path);

    // 기본 conditions에 "import"가 포함되어 esm.js 선택
    try std.testing.expect(pathEndsWith(result.path, "exp-pkg/esm.js"));
}

test "resolve: bare specifier with index fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(tmp.dir, "node_modules/simple/package.json", "{\"name\":\"simple\"}");
    try createFile(tmp.dir, "node_modules/simple/index.js");

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(dir_path, "simple");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "simple/index.js"));
}

test "resolve: bare specifier walk up directories" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // node_modules는 루트에, 소스 파일은 src/deep/ 에
    try writeFile(tmp.dir, "node_modules/top-pkg/package.json", "{\"main\":\"./index.js\"}");
    try createFile(tmp.dir, "node_modules/top-pkg/index.js");
    try createFile(tmp.dir, "src/deep/entry.ts");

    const deep_path = try tmp.dir.realpathAlloc(std.testing.allocator, "src/deep");
    defer std.testing.allocator.free(deep_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = try resolver.resolve(deep_path, "top-pkg");
    defer std.testing.allocator.free(result.path);

    try std.testing.expect(pathEndsWith(result.path, "top-pkg/index.js"));
}

test "resolve: bare specifier not found" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var resolver = Resolver.init(std.testing.allocator);
    const result = resolver.resolve(dir_path, "nonexistent-pkg");
    try std.testing.expectError(error.ModuleNotFound, result);
}

test "splitBareSpecifier" {
    const s1 = splitBareSpecifier("react");
    try std.testing.expectEqualStrings("react", s1.pkg_name);
    try std.testing.expectEqualStrings(".", s1.subpath);

    const s2 = splitBareSpecifier("react/jsx-runtime");
    try std.testing.expectEqualStrings("react", s2.pkg_name);
    try std.testing.expectEqualStrings("jsx-runtime", s2.subpath);

    const s3 = splitBareSpecifier("@mui/material");
    try std.testing.expectEqualStrings("@mui/material", s3.pkg_name);
    try std.testing.expectEqualStrings(".", s3.subpath);

    const s4 = splitBareSpecifier("@mui/material/Button");
    try std.testing.expectEqualStrings("@mui/material", s4.pkg_name);
    try std.testing.expectEqualStrings("Button", s4.subpath);
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
    try std.testing.expect(pathEndsWith(result.path, "mod.ts"));
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
    try std.testing.expect(pathEndsWith(result.path, "lib.js"));
}
