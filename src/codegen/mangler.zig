//! ZTS Identifier Mangler (MVP)
//!
//! 스코프 분석을 기반으로 로컬 변수 이름을 짧은 이름으로 교체한다.
//! 번들 크기를 ~70% 절감하는 핵심 최적화.
//!
//! MVP 전략: 스코프별 순차 이름 배정 (a, b, c, ..., z, A, ..., Z, aa, ab, ...)
//! 후속: oxc 방식 빈도 기반 + 슬롯 재사용 + Base54
//!
//! 규칙:
//!   - export된 심볼은 mangling 하지 않음
//!   - import 바인딩은 mangling 하지 않음 (번들러가 처리)
//!   - 예약어/글로벌 이름은 건너뜀
//!   - 함수 파라미터도 mangling 대상
//!   - 스코프 내 기존 1글자 이름과 충돌 방지 (부모 체인 포함)
//!
//! 미구현 (후속):
//!   - eval 포함 스코프 mangling 스킵
//!   - 빈도 기반 이름 배정 (oxc Base54)

const std = @import("std");
const Scope = @import("../semantic/scope.zig").Scope;
const ScopeId = @import("../semantic/scope.zig").ScopeId;
const Symbol = @import("../semantic/symbol.zig").Symbol;

pub const ManglerResult = struct {
    /// symbol_id → 새 이름. codegen의 linking_metadata.renames에 주입.
    renames: std.AutoHashMap(u32, []const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ManglerResult) void {
        var it = self.renames.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.renames.deinit();
    }
};

/// 스코프/심볼 데이터를 받아 mangling rename 맵을 생성한다.
pub fn mangle(
    allocator: std.mem.Allocator,
    scopes: []const Scope,
    symbols: []const Symbol,
    scope_maps: []const std.StringHashMap(usize),
) !ManglerResult {
    var renames = std.AutoHashMap(u32, []const u8).init(allocator);
    errdefer {
        var it = renames.valueIterator();
        while (it.next()) |v| allocator.free(v.*);
        renames.deinit();
    }

    // 스코프별로 순회하며 mangling 대상 심볼에 짧은 이름 배정.
    // 각 스코프에서 이름 생성기를 리셋하여 스코프 간 이름 재사용.
    for (scope_maps, 0..) |scope_map, scope_idx| {
        if (scope_idx >= scopes.len) break;
        const scope = scopes[scope_idx];

        // 스코프 내 기존 이름 수집 (mangling 안 되는 이름 = 점유 이름)
        // 생성된 이름이 이들과 충돌하면 건너뜀
        var occupied = std.StringHashMap(void).init(allocator);
        defer occupied.deinit();

        // 현재 스코프의 mangling 제외 이름
        var sit1 = scope_map.iterator();
        while (sit1.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const sym_idx = entry.value_ptr.*;
            if (sym_idx < symbols.len and shouldSkip(symbols[sym_idx], sym_name)) {
                try occupied.put(sym_name, {});
            }
        }

        // 부모 스코프 체인의 모든 이름도 점유 (shadowing 방지)
        var parent_id = scope.parent;
        while (!parent_id.isNone()) {
            const pi = parent_id.toIndex();
            if (pi < scope_maps.len) {
                var pit = scope_maps[pi].iterator();
                while (pit.next()) |entry| {
                    // 부모 스코프에서 mangling 안 되는 이름만 점유
                    const pname = entry.key_ptr.*;
                    const pidx = entry.value_ptr.*;
                    if (pidx < symbols.len and shouldSkip(symbols[pidx], pname)) {
                        try occupied.put(pname, {});
                    }
                }
            }
            if (pi < scopes.len) {
                parent_id = scopes[pi].parent;
            } else break;
        }

        var name_gen = NameGenerator{};

        var sit = scope_map.iterator();
        while (sit.next()) |entry| {
            const sym_name = entry.key_ptr.*;
            const sym_idx = entry.value_ptr.*;

            if (sym_idx >= symbols.len) continue;
            const sym = symbols[sym_idx];

            if (shouldSkip(sym, sym_name)) continue;

            // 짧은 이름 생성 (예약어 + 점유 이름 충돌 방지)
            var new_name = name_gen.next();
            while (isReservedOrGlobal(new_name) or occupied.contains(new_name)) {
                new_name = name_gen.next();
            }

            if (std.mem.eql(u8, sym_name, new_name)) continue;

            try renames.put(@intCast(sym_idx), try allocator.dupe(u8, new_name));
        }
    }

    return .{ .renames = renames, .allocator = allocator };
}

/// mangling 제외 여부 판단
fn shouldSkip(sym: Symbol, name: []const u8) bool {
    // export된 심볼
    if (sym.decl_flags.is_exported or sym.decl_flags.is_default_export) return true;
    // import 바인딩
    if (sym.decl_flags.is_import) return true;
    // "arguments" 특수 이름
    if (std.mem.eql(u8, name, "arguments")) return true;
    // 이미 1문자면 mangling 불필요
    if (name.len <= 1) return true;
    return false;
}

// ============================================================
// 이름 생성기 (순차: a, b, ..., z, A, ..., Z, aa, ab, ...)
// ============================================================

const NameGenerator = struct {
    counter: u32 = 0,
    buf: [8]u8 = undefined,

    fn next(self: *NameGenerator) []const u8 {
        const result = encode(self.counter, &self.buf);
        self.counter += 1;
        return result;
    }

    /// 숫자를 짧은 식별자로 인코딩.
    /// 0→"a", 25→"z", 26→"A", 51→"Z", 52→"_", 53→"$", 54→"aa", 55→"ab", ...
    fn encode(n: u32, buf: []u8) []const u8 {
        const first_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$";
        const all_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$0123456789";
        const first_len: u32 = @intCast(first_chars.len); // 54
        const all_len: u32 = @intCast(all_chars.len); // 64

        if (n < first_len) {
            buf[0] = first_chars[n];
            return buf[0..1];
        }

        // 2글자 이상: first_char + all_chars*
        var remaining = n - first_len;
        var len: usize = 0;

        // 첫 글자 (IdentifierStart)
        buf[len] = first_chars[@intCast(remaining % first_len)];
        len += 1;
        remaining /= first_len;

        // 두 번째 글자부터 (IdentifierPart, 숫자 포함)
        buf[len] = all_chars[@intCast(remaining % all_len)];
        len += 1;
        remaining /= all_len;

        while (remaining > 0 and len < buf.len - 1) {
            buf[len] = all_chars[@intCast(remaining % all_len)];
            len += 1;
            remaining /= all_len;
        }

        return buf[0..len];
    }
};

// ============================================================
// 예약어/글로벌 체크
// ============================================================

fn isReservedOrGlobal(name: []const u8) bool {
    // JS 예약어 (2~3글자만 체크 — 1글자와 4글자+는 충돌 없음)
    const reserved = [_][]const u8{
        "do",  "if",  "in",  "as",  "is",
        "for", "let", "new", "try", "var",
        "NaN",
    };
    for (reserved) |r| {
        if (std.mem.eql(u8, name, r)) return true;
    }

    // 글로벌 객체 (1~2글자)
    // undefined, window, console 등은 3글자+ 이므로 충돌 안 함
    return false;
}

// ============================================================
// Tests
// ============================================================

test "NameGenerator: sequential encoding" {
    var gen = NameGenerator{};
    try std.testing.expectEqualStrings("a", gen.next());
    try std.testing.expectEqualStrings("b", gen.next());

    // 26번째: z
    gen.counter = 25;
    try std.testing.expectEqualStrings("z", gen.next());

    // 27번째: A
    try std.testing.expectEqualStrings("A", gen.next());

    // 54번째(인덱스 54)부터 2글자
    gen.counter = 54;
    const two_char = gen.next();
    try std.testing.expect(two_char.len == 2);
}

test "NameGenerator: skips reserved words" {
    // "do" = encode(?) 이 나오면 건너뛰는지 확인
    const gen = NameGenerator{};
    _ = gen;
    try std.testing.expect(isReservedOrGlobal("do"));
    try std.testing.expect(isReservedOrGlobal("if"));
    try std.testing.expect(isReservedOrGlobal("in"));
    try std.testing.expect(!isReservedOrGlobal("a"));
    try std.testing.expect(!isReservedOrGlobal("foo"));
}
