//! ZTS Bundler — Resolve Cache + External 처리
//!
//! D064 (import kind별 resolver), D069 (external 옵션), D081 (3계층 Layer 2).
//!
//! 역할:
//!   1. external 패턴 매칭 (문자열 + `*` 글롭)
//!   2. resolve 결과 캐싱 (동일 specifier 재해석 방지)
//!   3. 플랫폼별 node 빌트인 자동 external
//!
//! 참고:
//!   - references/rolldown/crates/rolldown_resolver/src/resolver.rs (캐시 + kind별 분리)
//!   - references/esbuild/pkg/api/api.go (External []string)

const std = @import("std");
const resolver_mod = @import("resolver.zig");
const Resolver = resolver_mod.Resolver;
const ResolveResult = resolver_mod.ResolveResult;
const ResolveError = resolver_mod.ResolveError;
const types = @import("types.zig");
const ImportKind = types.ImportKind;

pub const Platform = enum {
    browser,
    node,
    neutral,
};

/// Node.js 빌트인 모듈 목록 (node: 프리픽스 없이).
/// platform=node일 때 자동 external로 처리.
const node_builtins: []const []const u8 = &.{
    "assert",         "async_hooks",         "buffer",     "child_process",
    "cluster",        "console",             "constants",  "crypto",
    "dgram",          "diagnostics_channel", "dns",        "domain",
    "events",         "fs",                  "http",       "http2",
    "https",          "inspector",           "module",     "net",
    "os",             "path",                "perf_hooks", "process",
    "punycode",       "querystring",         "readline",   "repl",
    "stream",         "string_decoder",      "sys",        "timers",
    "tls",            "trace_events",        "tty",        "url",
    "util",           "v8",                  "vm",         "wasi",
    "worker_threads", "zlib",
};

pub const ResolveCache = struct {
    allocator: std.mem.Allocator,
    resolver: Resolver,
    cache: std.StringHashMap(CachedResult),
    external_patterns: []const []const u8,
    platform: Platform,

    const CachedResult = union(enum) {
        resolved: ResolveResult,
        external,
        not_found,
    };

    pub fn init(allocator: std.mem.Allocator, platform: Platform, external_patterns: []const []const u8) ResolveCache {
        return .{
            .allocator = allocator,
            .resolver = Resolver.init(allocator),
            .cache = std.StringHashMap(CachedResult).init(allocator),
            .external_patterns = external_patterns,
            .platform = platform,
        };
    }

    pub fn deinit(self: *ResolveCache) void {
        // 캐시된 경로 문자열 해제
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .resolved => |r| self.allocator.free(r.path),
                else => {},
            }
        }
        self.cache.deinit();
    }

    /// specifier를 해석한다. 캐시 히트 시 캐시에서 반환.
    pub fn resolve(
        self: *ResolveCache,
        source_dir: []const u8,
        specifier: []const u8,
        kind: ImportKind,
    ) ResolveError!?ResolveResult {
        // 1. external 체크 (캐시 전에, 항상 먼저)
        if (self.isExternal(specifier)) return null;

        // 2. 캐시 조회
        const cache_key = self.makeCacheKey(source_dir, specifier, kind) catch
            return error.OutOfMemory;
        defer self.allocator.free(cache_key);

        if (self.cache.get(cache_key)) |cached| {
            return switch (cached) {
                // 캐시 히트: caller 소유 복사본 반환 (Critical #2 수정)
                .resolved => |r| ResolveResult{
                    .path = self.allocator.dupe(u8, r.path) catch return error.OutOfMemory,
                    .module_type = r.module_type,
                },
                .external => null,
                .not_found => error.ModuleNotFound,
            };
        }

        // 3. 실제 resolve — import kind에 따라 조건 세트를 교체 (D064)
        //    require() → "require" 조건, 그 외 → "import" 조건
        //    예: is-promise의 exports { "import": "./esm.mjs", "require": "./cjs.js" }
        const saved_conditions = self.resolver.conditions;
        if (kind == .require) {
            self.resolver.conditions = &.{ "require", "module", "browser", "default" };
        }
        defer self.resolver.conditions = saved_conditions;

        const result = self.resolver.resolve(source_dir, specifier) catch |err| switch (err) {
            error.ModuleNotFound => {
                try self.putCache(cache_key, .not_found);
                return error.ModuleNotFound;
            },
            else => return err,
        };

        // 4. 캐시에 저장 (캐시가 path를 소유, caller에게는 별도 복사본)
        const cache_path = self.allocator.dupe(u8, result.path) catch return error.OutOfMemory;
        try self.putCache(cache_key, .{ .resolved = .{
            .path = cache_path,
            .module_type = result.module_type,
        } });

        // result.path는 resolver가 할당한 것 — caller 소유로 그대로 반환
        return result;
    }

    /// 캐시에 엔트리 저장. 기존 키가 있으면 이전 키/값 해제 (Critical #1 수정).
    fn putCache(self: *ResolveCache, cache_key: []const u8, value: CachedResult) !void {
        // 기존 엔트리가 있으면 해제
        if (self.cache.fetchRemove(cache_key)) |old| {
            self.allocator.free(old.key);
            switch (old.value) {
                .resolved => |r| self.allocator.free(r.path),
                else => {},
            }
        }
        const key_owned = self.allocator.dupe(u8, cache_key) catch return error.OutOfMemory;
        self.cache.put(key_owned, value) catch return error.OutOfMemory;
    }

    /// specifier가 external인지 판별.
    /// exact match + `*` 글롭 매칭 (D069).
    fn isExternal(self: *const ResolveCache, specifier: []const u8) bool {
        // node: 프리픽스
        if (std.mem.startsWith(u8, specifier, "node:")) {
            return true;
        }

        // platform=node이면 node 빌트인 자동 external
        if (self.platform == .node) {
            for (node_builtins) |builtin| {
                if (std.mem.eql(u8, specifier, builtin)) return true;
            }
        }

        // 사용자 지정 external 패턴
        for (self.external_patterns) |pattern| {
            if (matchGlob(pattern, specifier)) return true;
        }

        return false;
    }

    fn makeCacheKey(self: *ResolveCache, source_dir: []const u8, specifier: []const u8, kind: ImportKind) ![]const u8 {
        const kind_str = @tagName(kind);
        return std.mem.concat(self.allocator, u8, &.{ source_dir, "\x00", specifier, "\x00", kind_str });
    }
};

/// 글롭 패턴 매칭. `*`는 `/` 제외 모든 문자에 매칭 (D069).
/// "react" matches "react"
/// "@mui/*" matches "@mui/material" but not "@mui/icons/filled"
/// "node:*" matches "node:fs", "node:path"
pub fn matchGlob(pattern: []const u8, text: []const u8) bool {
    if (std.mem.indexOf(u8, pattern, "*")) |star_pos| {
        const prefix = pattern[0..star_pos];
        const suffix = pattern[star_pos + 1 ..];

        if (!std.mem.startsWith(u8, text, prefix)) return false;
        if (text.len < prefix.len + suffix.len) return false;
        if (!std.mem.endsWith(u8, text, suffix)) return false;

        // * 가 매칭한 부분에 / 가 있으면 불매칭
        const matched = text[prefix.len .. text.len - suffix.len];
        return std.mem.indexOf(u8, matched, "/") == null;
    }

    // 글롭 없으면 exact match
    return std.mem.eql(u8, pattern, text);
}

// ============================================================
// Tests
// ============================================================

test "matchGlob: exact match" {
    try std.testing.expect(matchGlob("react", "react"));
    try std.testing.expect(!matchGlob("react", "react-dom"));
}

test "matchGlob: wildcard" {
    try std.testing.expect(matchGlob("@mui/*", "@mui/material"));
    try std.testing.expect(matchGlob("@mui/*", "@mui/icons"));
    // * 는 / 를 매칭하지 않음
    try std.testing.expect(!matchGlob("@mui/*", "@mui/icons/filled"));
}

test "matchGlob: node: prefix" {
    try std.testing.expect(matchGlob("node:*", "node:fs"));
    try std.testing.expect(matchGlob("node:*", "node:path"));
    try std.testing.expect(!matchGlob("node:*", "node:fs/promises"));
}

test "isExternal: node: prefix always external" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("node:fs"));
    try std.testing.expect(cache.isExternal("node:path"));
    try std.testing.expect(!cache.isExternal("react"));
}

test "isExternal: node builtins when platform=node" {
    var cache = ResolveCache.init(std.testing.allocator, .node, &.{});
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("fs"));
    try std.testing.expect(cache.isExternal("path"));
    try std.testing.expect(cache.isExternal("crypto"));
    try std.testing.expect(!cache.isExternal("react"));
}

test "isExternal: node builtins NOT external when platform=browser" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();

    try std.testing.expect(!cache.isExternal("fs"));
    try std.testing.expect(!cache.isExternal("path"));
}

test "isExternal: user patterns" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{ "react", "@mui/*" });
    defer cache.deinit();

    try std.testing.expect(cache.isExternal("react"));
    try std.testing.expect(cache.isExternal("@mui/material"));
    try std.testing.expect(!cache.isExternal("vue"));
}

test "resolve: external returns null" {
    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{"react"});
    defer cache.deinit();

    const result = try cache.resolve("/some/dir", "react", .static_import);
    try std.testing.expect(result == null);
}

test "resolve: cache hit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    // 파일 생성
    const file = try tmp.dir.createFile("foo.ts", .{});
    file.close();

    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();

    // 첫 번째 호출 (캐시 미스) — caller 소유
    const result1 = try cache.resolve(dir_path, "./foo", .static_import);
    try std.testing.expect(result1 != null);
    defer std.testing.allocator.free(result1.?.path);
    try std.testing.expect(std.mem.endsWith(u8, result1.?.path, "foo.ts"));

    // 두 번째 호출 (캐시 히트) — 별도 할당, caller 소유
    const result2 = try cache.resolve(dir_path, "./foo", .static_import);
    try std.testing.expect(result2 != null);
    defer std.testing.allocator.free(result2.?.path);
    try std.testing.expect(std.mem.endsWith(u8, result2.?.path, "foo.ts"));

    // 내용은 같지만 포인터는 다름 (각각 독립 할당)
    try std.testing.expectEqualStrings(result1.?.path, result2.?.path);
    try std.testing.expect(result1.?.path.ptr != result2.?.path.ptr);
}

test "resolve: not found cached" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir_path);

    var cache = ResolveCache.init(std.testing.allocator, .browser, &.{});
    defer cache.deinit();

    // 존재하지 않는 파일
    const r1 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r1);

    // 두 번째 호출도 ModuleNotFound (캐시에서)
    const r2 = cache.resolve(dir_path, "./nonexistent", .static_import);
    try std.testing.expectError(error.ModuleNotFound, r2);
}
