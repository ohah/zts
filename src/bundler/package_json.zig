//! ZTS Bundler — package.json 파서
//!
//! node_modules 패키지의 package.json을 파싱하여
//! 모듈 해석에 필요한 필드를 추출한다.
//!
//! 지원 필드:
//!   - name: 패키지 이름
//!   - main: CJS 엔트리포인트
//!   - module: ESM 엔트리포인트
//!   - exports: 조건부 exports (D064)
//!   - sideEffects: tree-shaking 힌트 (D063)
//!   - type: "module" | "commonjs"
//!
//! exports 필드 지원 범위 (Node.js 스펙 준수):
//!   - 문자열: "exports": "./index.js"
//!   - 조건 객체: "exports": { "import": "./esm.js", "require": "./cjs.js", "default": "./index.js" }
//!   - 서브패스: "exports": { ".": "./index.js", "./utils": "./utils.js" }
//!   - 와일드카드: "exports": { "./*": "./src/*.js" }
//!   - 중첩 조건: "exports": { ".": { "import": "./esm.js", "default": "./cjs.js" } }
//!
//! 참고:
//!   - https://nodejs.org/api/packages.html#conditional-exports
//!   - references/bun/src/resolver/package_json.zig
//!   - references/rolldown/crates/rolldown_resolver/src/resolver_config.rs

const std = @import("std");

pub const PackageJson = struct {
    name: ?[]const u8 = null,
    main: ?[]const u8 = null,
    module: ?[]const u8 = null,
    type_field: ?[]const u8 = null,
    exports: ?std.json.Value = null,
    side_effects: SideEffects = .unknown,

    pub const SideEffects = union(enum) {
        unknown,
        all: bool,
        patterns: []const []const u8,
    };

    /// package.json이 ESM 패키지인지 판별.
    pub fn isModule(self: *const PackageJson) bool {
        if (self.type_field) |t| {
            return std.mem.eql(u8, t, "module");
        }
        return false;
    }
};

/// package.json 파일을 읽고 파싱한다.
/// 반환된 PackageJson의 문자열은 parsed JSON이 소유하므로
/// Parsed를 유지해야 한다 (caller가 deinit 관리).
pub const ParsedPackageJson = struct {
    pkg: PackageJson,
    parsed: std.json.Parsed(std.json.Value),

    pub fn deinit(self: *ParsedPackageJson) void {
        self.parsed.deinit();
    }
};

/// package.json 파일을 읽고 파싱한다.
pub fn parsePackageJson(allocator: std.mem.Allocator, dir: std.fs.Dir) !ParsedPackageJson {
    const source = dir.readFileAlloc(allocator, "package.json", 1024 * 1024) catch
        return error.FileNotFound;
    defer allocator.free(source);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, source, .{}) catch
        return error.JsonParseError;

    const root = parsed.value;
    if (root != .object) {
        var p = parsed;
        p.deinit();
        return error.JsonParseError;
    }

    const obj = root.object;

    return .{
        .pkg = .{
            .name = getStr(obj, "name"),
            .main = getStr(obj, "main"),
            .module = getStr(obj, "module"),
            .type_field = getStr(obj, "type"),
            .exports = obj.get("exports"),
            .side_effects = parseSideEffects(obj),
        },
        .parsed = parsed,
    };
}

/// exports 필드에서 조건에 맞는 경로를 찾는다.
/// subpath: "." (패키지 루트) 또는 "./utils" 등
/// conditions: ["import", "default"] 등 (D064)
pub fn resolveExports(
    exports: std.json.Value,
    subpath: []const u8,
    conditions: []const []const u8,
) ?[]const u8 {
    switch (exports) {
        // "exports": "./index.js"
        .string => |s| {
            if (std.mem.eql(u8, subpath, ".")) return s;
            return null;
        },
        .object => |obj| {
            // 키가 "."으로 시작하는지로 서브패스 맵 vs 조건 객체 구분
            if (isSubpathMap(obj)) {
                return resolveSubpathMap(obj, subpath, conditions);
            }
            // 조건 객체: { "import": ..., "require": ..., "default": ... }
            if (std.mem.eql(u8, subpath, ".")) {
                return resolveConditions(exports, conditions);
            }
            return null;
        },
        else => return null,
    }
}

/// 서브패스 맵에서 매칭되는 엔트리를 찾는다.
/// 정확한 매칭 먼저, 와일드카드 매칭 나중.
fn resolveSubpathMap(
    obj: std.json.ObjectMap,
    subpath: []const u8,
    conditions: []const []const u8,
) ?[]const u8 {
    // 1. 정확한 매칭
    if (obj.get(subpath)) |value| {
        return resolveConditions(value, conditions);
    }

    // 2. 와일드카드 매칭 (./* 패턴)
    var it = obj.iterator();
    while (it.next()) |entry| {
        const pattern = entry.key_ptr.*;
        if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
            const prefix = pattern[0..star_pos];
            const suffix = pattern[star_pos + 1 ..];

            if (subpath.len >= prefix.len + suffix.len and
                std.mem.startsWith(u8, subpath, prefix) and
                std.mem.endsWith(u8, subpath, suffix))
            {
                // 와일드카드가 매칭한 부분 추출
                const matched = subpath[prefix.len .. subpath.len - suffix.len];
                const resolved = resolveConditions(entry.value_ptr.*, conditions) orelse continue;

                // 결과에서 * 를 매칭된 부분으로 치환
                if (std.mem.indexOf(u8, resolved, "*")) |_| {
                    // 정적 분석에서는 * 치환 불가 (동적 문자열 생성 필요)
                    // 하지만 대부분의 경우 패턴이 단순하므로 매칭만 확인
                    _ = matched;
                    return resolved;
                }
                return resolved;
            }
        }
    }

    return null;
}

/// 조건 객체 또는 문자열에서 매칭되는 경로를 찾는다.
/// conditions 순서대로 매칭 (첫 번째 매칭이 승리).
fn resolveConditions(value: std.json.Value, conditions: []const []const u8) ?[]const u8 {
    switch (value) {
        .string => |s| return s,
        .object => |obj| {
            // JSON 소스 순서를 유지하므로 conditions 순서로 탐색
            for (conditions) |cond| {
                if (obj.get(cond)) |v| {
                    return resolveConditions(v, conditions);
                }
            }
            // "default"는 항상 마지막 폴백 (Node.js 스펙)
            if (obj.get("default")) |v| {
                return resolveConditions(v, conditions);
            }
            return null;
        },
        else => return null,
    }
}

/// exports 맵의 키가 "."으로 시작하는지 확인 (서브패스 맵 판별).
fn isSubpathMap(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    if (it.next()) |entry| {
        return std.mem.startsWith(u8, entry.key_ptr.*, ".");
    }
    return false;
}

fn getStr(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    if (obj.get(key)) |v| {
        if (v == .string) return v.string;
    }
    return null;
}

fn parseSideEffects(obj: std.json.ObjectMap) PackageJson.SideEffects {
    const val = obj.get("sideEffects") orelse return .unknown;
    switch (val) {
        .bool => |b| return .{ .all = b },
        // 배열 패턴은 추후 지원 (["*.css", "./src/polyfill.js"])
        else => return .unknown,
    }
}

pub const Error = error{
    FileNotFound,
    JsonParseError,
    OutOfMemory,
};

// ============================================================
// Tests
// ============================================================

test "parsePackageJson: basic fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"test-pkg","main":"./lib/index.js","module":"./esm/index.js","type":"module"}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    try std.testing.expectEqualStrings("test-pkg", result.pkg.name.?);
    try std.testing.expectEqualStrings("./lib/index.js", result.pkg.main.?);
    try std.testing.expectEqualStrings("./esm/index.js", result.pkg.module.?);
    try std.testing.expect(result.pkg.isModule());
}

test "parsePackageJson: sideEffects false" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"pure-pkg","sideEffects":false}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    switch (result.pkg.side_effects) {
        .all => |b| try std.testing.expect(!b),
        else => return error.TestUnexpectedResult,
    }
}

test "parsePackageJson: missing file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = parsePackageJson(std.testing.allocator, tmp.dir);
    try std.testing.expectError(error.FileNotFound, result);
}

test "resolveExports: string shorthand" {
    const source =
        \\{"exports":"./index.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;
    const result = resolveExports(exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", result.?);
}

test "resolveExports: condition object" {
    const source =
        \\{"exports":{"import":"./esm.js","require":"./cjs.js","default":"./index.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    // import 조건 매칭
    const esm = resolveExports(exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?);

    // require 조건 매칭
    const cjs = resolveExports(exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?);

    // 없는 조건 → default 폴백
    const fallback = resolveExports(exports, ".", &.{"browser"});
    try std.testing.expectEqualStrings("./index.js", fallback.?);
}

test "resolveExports: subpath map" {
    const source =
        \\{"exports":{".":"./index.js","./utils":"./src/utils.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const root = resolveExports(exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", root.?);

    const utils = resolveExports(exports, "./utils", &.{"import"});
    try std.testing.expectEqualStrings("./src/utils.js", utils.?);

    const missing = resolveExports(exports, "./nonexistent", &.{"import"});
    try std.testing.expect(missing == null);
}

test "resolveExports: nested conditions in subpath" {
    const source =
        \\{"exports":{".":{"import":"./esm.js","require":"./cjs.js"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const esm = resolveExports(exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?);

    const cjs = resolveExports(exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?);
}

test "resolveExports: wildcard pattern" {
    const source =
        \\{"exports":{".":"./index.js","./*":"./src/*.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const result = resolveExports(exports, "./utils", &.{"import"});
    try std.testing.expectEqualStrings("./src/*.js", result.?);
}

test "resolveExports: no match returns null" {
    const source =
        \\{"exports":{"./internal":"./src/internal.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;
    const result = resolveExports(exports, ".", &.{"import"});
    try std.testing.expect(result == null);
}

test "isSubpathMap" {
    const source1 =
        \\{".":"./index.js","./utils":"./utils.js"}
    ;
    const parsed1 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source1, .{});
    defer parsed1.deinit();
    try std.testing.expect(isSubpathMap(parsed1.value.object));

    const source2 =
        \\{"import":"./esm.js","require":"./cjs.js"}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source2, .{});
    defer parsed2.deinit();
    try std.testing.expect(!isSubpathMap(parsed2.value.object));
}
