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
    imports: ?std.json.Value = null,
    /// "browser" 필드 (object 형태). 키: 상대 경로, 값: false 또는 대체 경로.
    /// platform=browser에서 파일 교체/비활성화에 사용.
    /// https://github.com/defunctzombie/package-browser-field-spec
    browser_map: ?std.json.Value = null,
    side_effects: SideEffects = .unknown,

    pub const SideEffects = union(enum) {
        unknown,
        all: bool,
        patterns: []const []const u8,

        /// allocator로 dupe된 패턴 문자열 해제. .all/.unknown은 no-op.
        pub fn deinit(self: SideEffects, allocator: std.mem.Allocator) void {
            switch (self) {
                .patterns => |patterns| {
                    for (patterns) |p| allocator.free(p);
                    allocator.free(patterns);
                },
                else => {},
            }
        }
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
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ParsedPackageJson) void {
        self.pkg.side_effects.deinit(self.allocator);
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

    // "browser" 필드: object 형태만 browser_map으로 저장.
    // string 형태("browser": "lib/browser.js")는 main 대체이므로 별도 처리 불필요 (exports/main에서 커버).
    const browser_map: ?std.json.Value = if (obj.get("browser")) |b| switch (b) {
        .object => b,
        else => null,
    } else null;

    return .{
        .pkg = .{
            .name = getStr(obj, "name"),
            .main = getStr(obj, "main"),
            .module = getStr(obj, "module"),
            .type_field = getStr(obj, "type"),
            .exports = obj.get("exports"),
            .imports = obj.get("imports"),
            .browser_map = browser_map,
            .side_effects = parseSideEffects(obj, allocator),
        },
        .parsed = parsed,
        .allocator = allocator,
    };
}

/// exports 필드에서 조건에 맞는 경로를 찾는다.
/// subpath: "." (패키지 루트) 또는 "./utils" 등
/// conditions: ["import", "default"] 등 (D064)
/// exports 필드에서 조건에 맞는 경로를 찾는다.
/// 와일드카드 치환이 필요한 경우 allocator로 새 문자열을 할당.
/// 반환된 문자열이 allocated인지 여부는 caller가 판별해야 함 — allocated_result로 반환.
pub const ExportsResult = struct {
    path: []const u8,
    allocated: bool,
};

pub fn resolveExports(
    allocator: std.mem.Allocator,
    exports: std.json.Value,
    subpath: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    switch (exports) {
        .string => |s| {
            if (std.mem.eql(u8, subpath, ".")) return .{ .path = s, .allocated = false };
            return null;
        },
        .object => |obj| {
            if (isSubpathMap(obj)) {
                return resolveSubpathMap(allocator, obj, subpath, conditions);
            }
            if (std.mem.eql(u8, subpath, ".")) {
                if (resolveConditions(exports, conditions)) |path| {
                    return .{ .path = path, .allocated = false };
                }
            }
            return null;
        },
        else => return null,
    }
}

/// imports 필드에서 `#specifier`에 맞는 경로를 찾는다.
/// Node.js subpath imports: package.json "imports" 필드로 패키지 내부 import 매핑.
/// 정확한 매칭 + 와일드카드는 resolveSubpathMap과 동일 로직 (재사용).
/// https://nodejs.org/api/packages.html#subpath-imports
pub fn resolveImports(
    allocator: std.mem.Allocator,
    imports: std.json.Value,
    specifier: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    switch (imports) {
        .object => |obj| return resolveSubpathMap(allocator, obj, specifier, conditions),
        else => return null,
    }
}

/// 서브패스 맵에서 매칭되는 엔트리를 찾는다.
/// 정확한 매칭 먼저, 와일드카드 매칭 나중.
fn resolveSubpathMap(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    subpath: []const u8,
    conditions: []const []const u8,
) ?ExportsResult {
    // 1. 정확한 매칭
    if (obj.get(subpath)) |value| {
        if (resolveConditions(value, conditions)) |path| {
            return .{ .path = path, .allocated = false };
        }
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
                const matched = subpath[prefix.len .. subpath.len - suffix.len];
                const resolved = resolveConditions(entry.value_ptr.*, conditions) orelse continue;

                // 결과에서 * 를 매칭된 부분으로 치환
                if (std.mem.indexOf(u8, resolved, "*")) |res_star| {
                    const before = resolved[0..res_star];
                    const after = resolved[res_star + 1 ..];
                    const substituted = std.mem.concat(allocator, u8, &.{ before, matched, after }) catch return null;
                    return .{ .path = substituted, .allocated = true };
                }
                return .{ .path = resolved, .allocated = false };
            }
        }
    }

    return null;
}

/// 조건 객체, 문자열, 또는 폴백 배열에서 매칭되는 경로를 찾는다.
/// conditions 순서대로 매칭 (첫 번째 매칭이 승리).
/// 배열(fallback array)은 Node.js 스펙에서 지원하며, 순서대로 시도하여 첫 번째 성공을 반환한다.
/// 예: "./shams": [{"types":"./shams.d.ts","default":"./shams.js"}, "./shams.js"]
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
        .array => |arr| {
            // 폴백 배열: 각 요소를 순서대로 시도, 첫 번째 매칭 반환
            for (arr.items) |item| {
                if (resolveConditions(item, conditions)) |result| {
                    return result;
                }
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

fn parseSideEffects(obj: std.json.ObjectMap, allocator: std.mem.Allocator) PackageJson.SideEffects {
    const val = obj.get("sideEffects") orelse return .unknown;
    switch (val) {
        .bool => |b| return .{ .all = b },
        .array => |arr| {
            // ["*.css", "./src/polyfill.js"] — 문자열 배열.
            // 빈 배열은 sideEffects: false와 동일.
            if (arr.items.len == 0) return .{ .all = false };
            // allocator로 패턴을 dupe — JSON parse tree 해제 후에도 유효.
            const patterns = allocator.alloc([]const u8, arr.items.len) catch return .unknown;
            for (arr.items, 0..) |item, i| {
                if (item != .string) {
                    for (patterns[0..i]) |p| allocator.free(p);
                    allocator.free(patterns);
                    return .unknown;
                }
                patterns[i] = allocator.dupe(u8, item.string) catch {
                    for (patterns[0..i]) |p| allocator.free(p);
                    allocator.free(patterns);
                    return .unknown;
                };
            }
            return .{ .patterns = patterns };
        },
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

test "parsePackageJson: sideEffects array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"css-pkg","sideEffects":["*.css","./src/polyfill.js"]}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    switch (result.pkg.side_effects) {
        .patterns => |patterns| {
            try std.testing.expectEqual(@as(usize, 2), patterns.len);
            try std.testing.expectEqualStrings("*.css", patterns[0]);
            try std.testing.expectEqualStrings("./src/polyfill.js", patterns[1]);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parsePackageJson: sideEffects empty array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"empty-pkg","sideEffects":[]}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    // 빈 배열은 sideEffects: false와 동일
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
    const result = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", result.?.path);
}

test "resolveExports: condition object" {
    const source =
        \\{"exports":{"import":"./esm.js","require":"./cjs.js","default":"./index.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    // import 조건 매칭
    const esm = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?.path);

    const cjs = resolveExports(std.testing.allocator, exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?.path);

    const fallback = resolveExports(std.testing.allocator, exports, ".", &.{"browser"});
    try std.testing.expectEqualStrings("./index.js", fallback.?.path);
}

test "resolveExports: subpath map" {
    const source =
        \\{"exports":{".":"./index.js","./utils":"./src/utils.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const root = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./index.js", root.?.path);

    const utils = resolveExports(std.testing.allocator, exports, "./utils", &.{"import"});
    try std.testing.expectEqualStrings("./src/utils.js", utils.?.path);

    const missing = resolveExports(std.testing.allocator, exports, "./nonexistent", &.{"import"});
    try std.testing.expect(missing == null);
}

test "resolveExports: nested conditions in subpath" {
    const source =
        \\{"exports":{".":{"import":"./esm.js","require":"./cjs.js"}}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const esm = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
    try std.testing.expectEqualStrings("./esm.js", esm.?.path);

    const cjs = resolveExports(std.testing.allocator, exports, ".", &.{"require"});
    try std.testing.expectEqualStrings("./cjs.js", cjs.?.path);
}

test "resolveExports: wildcard pattern" {
    const source =
        \\{"exports":{".":"./index.js","./*":"./src/*.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;

    const result = resolveExports(std.testing.allocator, exports, "./utils", &.{"import"});
    try std.testing.expect(result != null);
    defer if (result.?.allocated) std.testing.allocator.free(result.?.path);
    // 와일드카드 치환: ./* → ./utils, ./src/*.js → ./src/utils.js
    try std.testing.expectEqualStrings("./src/utils.js", result.?.path);
}

test "resolveExports: no match returns null" {
    const source =
        \\{"exports":{"./internal":"./src/internal.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const exports = parsed.value.object.get("exports").?;
    const result = resolveExports(std.testing.allocator, exports, ".", &.{"import"});
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

test "resolveImports: exact match" {
    const source =
        \\{"#ansi-styles":"./source/vendor/ansi-styles/index.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#ansi-styles", &.{ "import", "default" });
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("./source/vendor/ansi-styles/index.js", result.?.path);
    try std.testing.expect(!result.?.allocated);
}

test "resolveImports: condition object" {
    const source =
        \\{"#supports-color":{"node":"./source/vendor/supports-color/index.js","default":"./source/vendor/supports-color/browser.js"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    // node 조건 매칭
    const node_result = resolveImports(std.testing.allocator, parsed.value, "#supports-color", &.{ "node", "default" });
    try std.testing.expect(node_result != null);
    try std.testing.expectEqualStrings("./source/vendor/supports-color/index.js", node_result.?.path);

    // default 폴백
    const browser_result = resolveImports(std.testing.allocator, parsed.value, "#supports-color", &.{ "import", "browser" });
    try std.testing.expect(browser_result != null);
    try std.testing.expectEqualStrings("./source/vendor/supports-color/browser.js", browser_result.?.path);
}

test "resolveImports: wildcard pattern" {
    const source =
        \\{"#utils/*":"./src/utils/*.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#utils/string", &.{"default"});
    try std.testing.expect(result != null);
    defer if (result.?.allocated) std.testing.allocator.free(result.?.path);
    try std.testing.expectEqualStrings("./src/utils/string.js", result.?.path);
    try std.testing.expect(result.?.allocated);
}

test "resolveImports: no match returns null" {
    const source =
        \\{"#foo":"./foo.js"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, source, .{});
    defer parsed.deinit();

    const result = resolveImports(std.testing.allocator, parsed.value, "#bar", &.{"default"});
    try std.testing.expect(result == null);
}

test "parsePackageJson: imports field" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "package.json",
        .data =
        \\{"name":"chalk","imports":{"#ansi-styles":"./source/vendor/ansi-styles/index.js"}}
        ,
    });

    var result = try parsePackageJson(std.testing.allocator, tmp.dir);
    defer result.deinit();

    try std.testing.expect(result.pkg.imports != null);
}
