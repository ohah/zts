//! ZTS Bundler — 공유 타입 정의
//!
//! 번들러의 모든 모듈이 공유하는 기본 타입.
//! D066 (에러 핸들링), D070 (모듈 ID), D073 (모듈 타입), D079 (import 추출) 설계 반영.

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;

// ============================================================
// 모듈 ID (D070)
// ============================================================

/// 모듈 그래프에서 모듈을 식별하는 인덱스.
/// NodeIndex, SymbolId, ScopeId와 동일한 u32 enum 패턴.
pub const ModuleIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: ModuleIndex) bool {
        return self == .none;
    }
};

// ============================================================
// Import 종류
// ============================================================

/// import문의 종류. 모듈 그래프 엣지 분류에 사용.
pub const ImportKind = enum {
    /// import x from "./foo" / import { a } from "./foo"
    static_import,
    /// import("./foo")
    dynamic_import,
    /// export { x } from "./foo" / export * from "./foo"
    re_export,
    /// import "./foo" (specifier만, 바인딩 없음)
    side_effect,
    /// require("./foo") (CJS)
    require,
};

// ============================================================
// Export 방식 (CJS/ESM 판별)
// ============================================================

/// 모듈의 export 방식. CJS/ESM 판별에 사용 (esbuild ExportsKind).
pub const ExportsKind = enum {
    /// 아직 결정되지 않음 (script, no module system)
    none,
    /// CommonJS (require, module.exports, exports.x)
    commonjs,
    /// ESM (import/export)
    esm,
    /// ESM + CJS 혼용 (export * from cjs 등)
    esm_with_dynamic_fallback,
};

/// 모듈 래핑 방식 (esbuild WrapKind).
pub const WrapKind = enum {
    /// 래핑 없음 — ESM 모듈, 스코프 호이스팅 적용
    none,
    /// CJS 래핑 — __commonJS({ ... }) 팩토리 함수로 감싸기
    cjs,
};

// ============================================================
// 청크 인덱스 (Code Splitting)
// ============================================================

/// 청크 그래프에서 청크를 식별하는 인덱스.
pub const ChunkIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: ChunkIndex) bool {
        return self == .none;
    }
};

// ============================================================
// 모듈 타입 (D073)
// ============================================================

/// 파일 확장자 또는 설정에 의해 결정되는 모듈 타입.
/// ParserAndGenerator 패턴(rspack)의 기반.
pub const ModuleType = enum {
    javascript,
    json,
    css,
    asset,
    unknown,

    /// 파일 확장자로부터 모듈 타입을 추론한다.
    pub fn fromExtension(ext: []const u8) ModuleType {
        if (std.mem.eql(u8, ext, ".ts") or
            std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".js") or
            std.mem.eql(u8, ext, ".jsx") or
            std.mem.eql(u8, ext, ".mjs") or
            std.mem.eql(u8, ext, ".mts") or
            std.mem.eql(u8, ext, ".cjs") or
            std.mem.eql(u8, ext, ".cts"))
        {
            return .javascript;
        }
        if (std.mem.eql(u8, ext, ".json")) return .json;
        if (std.mem.eql(u8, ext, ".css")) return .css;
        return .unknown;
    }
};

// ============================================================
// Import 레코드 (D079)
// ============================================================

/// AST에서 추출한 단일 import/export 정보.
/// import_scanner가 AST 순회로 수집하고, 모듈 그래프가 resolve에 사용.
pub const ImportRecord = struct {
    /// 원본 import 경로 (예: "./foo", "react", "../utils")
    specifier: []const u8,
    /// import 종류
    kind: ImportKind,
    /// 소스 코드에서의 위치 (에러 메시지용)
    span: Span,
    /// resolve 완료 후 채워지는 모듈 인덱스
    resolved: ModuleIndex = .none,
};

// ============================================================
// 번들러 진단 정보 (D066)
// ============================================================

/// 번들러 에러/경고.
/// esbuild의 suggestion + Bun의 step enum 설계.
pub const BundlerDiagnostic = struct {
    /// 에러 코드 (프로그래밍적 처리용)
    code: ErrorCode,
    /// 심각도
    severity: Severity,
    /// 에러 메시지
    message: []const u8,
    /// 에러가 발생한 파일 경로
    file_path: []const u8,
    /// 소스 코드에서의 위치
    span: Span,
    /// 어느 단계에서 발생했는지 (Bun ParseTask.Error.Step 참고)
    step: Step,
    /// 해결 제안 (예: "Did you mean './foo.js'?")
    suggestion: ?[]const u8 = null,

    pub const ErrorCode = enum {
        /// import 경로를 resolve할 수 없음
        unresolved_import,
        /// export 이름을 찾을 수 없음
        missing_export,
        /// 순환 참조 감지
        circular_dependency,
        /// 파일 파싱 실패
        parse_error,
        /// 파일 읽기 실패
        read_error,
        /// JSON 파싱 실패
        json_parse_error,
    };

    pub const Severity = enum {
        @"error",
        warning,
        info,
    };

    pub const Step = enum {
        resolve,
        parse,
        transform,
        link,
        emit,
    };
};

// ============================================================
// Tests
// ============================================================

test "ModuleIndex: none sentinel" {
    try std.testing.expect(ModuleIndex.none.isNone());
    const idx: ModuleIndex = @enumFromInt(0);
    try std.testing.expect(!idx.isNone());
}

test "ModuleIndex: size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(ModuleIndex));
}

test "ModuleType: fromExtension" {
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".ts"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".tsx"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".js"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".jsx"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".mjs"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".mts"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".cjs"));
    try std.testing.expectEqual(ModuleType.javascript, ModuleType.fromExtension(".cts"));
    try std.testing.expectEqual(ModuleType.json, ModuleType.fromExtension(".json"));
    try std.testing.expectEqual(ModuleType.css, ModuleType.fromExtension(".css"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".png"));
    try std.testing.expectEqual(ModuleType.unknown, ModuleType.fromExtension(".wasm"));
}

// ============================================================
// 공유 유틸리티
// ============================================================

/// 모듈 경로에서 require_xxx 변수명을 생성한다.
/// "lib/foo-bar.cjs" → "require_foo_bar"
pub fn makeRequireVarName(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const basename = std.fs.path.basename(path);
    const stem = std.fs.path.stem(basename);

    var name: std.ArrayList(u8) = .empty;
    try name.appendSlice(allocator, "require_");
    for (stem) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            try name.append(allocator, c);
        } else {
            try name.append(allocator, '_');
        }
    }
    return name.toOwnedSlice(allocator);
}

/// Span을 u64 키로 변환. 번들러 전역에서 식별자/노드를 고유 식별하는 데 사용.
/// binding_scanner, linker 등에서 동일 함수를 공유하여 키 불일치 방지.
pub fn spanKey(span: Span) u64 {
    return @as(u64, span.start) << 32 | span.end;
}

/// 모듈 인덱스 + 이름 → 복합 키 (힙 할당). linker/tree_shaker의 export 맵에서 사용.
/// 형식: [4 bytes module_index][0x00][name bytes]
pub fn makeModuleKey(allocator: std.mem.Allocator, module_index: u32, name: []const u8) ![]const u8 {
    var buf = try allocator.alloc(u8, 4 + 1 + name.len);
    @memcpy(buf[0..4], std.mem.asBytes(&module_index));
    buf[4] = 0;
    @memcpy(buf[5..], name);
    return buf;
}

/// 모듈 인덱스 + 이름 → 복합 키 (스택 버퍼, 조회용). 할당 없음.
/// name이 4091바이트를 초과하면 assert 실패.
pub fn makeModuleKeyBuf(buf: *[4096]u8, module_index: u32, name: []const u8) []const u8 {
    const total = 5 + name.len;
    std.debug.assert(total <= 4096);
    @memcpy(buf[0..4], std.mem.asBytes(&module_index));
    buf[4] = 0;
    @memcpy(buf[5 .. 5 + name.len], name);
    return buf[0..total];
}

// ============================================================
// Tests
// ============================================================

test "ImportRecord: default resolved is none" {
    const record = ImportRecord{
        .specifier = "./foo",
        .kind = .static_import,
        .span = Span.EMPTY,
    };
    try std.testing.expect(record.resolved.isNone());
}

test "BundlerDiagnostic: default suggestion is null" {
    const diag = BundlerDiagnostic{
        .code = .unresolved_import,
        .severity = .@"error",
        .message = "Module not found",
        .file_path = "src/index.ts",
        .span = Span.EMPTY,
        .step = .resolve,
    };
    try std.testing.expect(diag.suggestion == null);
}
