//! ZTS RegExp Validator
//!
//! ECMAScript 정규식 리터럴의 유효성을 검증한다.
//! 렉서에서 `/pattern/flags` 토큰을 스캔한 후 호출.
//!
//! 설계:
//!   - comptime emit_ast 파라미터로 검증/AST 모드 분리
//!   - 현재: emit_ast=false (검증만, Test262 대응)
//!   - Phase 6: emit_ast=true (ES 다운레벨링, 미니파이어, WASM AST API)
//!   - 파싱 로직은 하나, 모드만 다름 → 리팩터링 불필요
//!
//! 모듈 구조:
//!   - mod.zig: 공개 API
//!   - flags.zig: 플래그 검증 (d/g/i/m/s/u/v/y)
//!   - parser.zig: 패턴 파서 (comptime emit_ast 지원)
//!   - diagnostics.zig: 에러 메시지
//!
//! 참고: references/oxc/crates/oxc_regular_expression

pub const flags = @import("flags.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const parser = @import("parser.zig");

/// 정규식 리터럴을 검증한다.
/// pattern: `/` 사이의 패턴 텍스트 (예: "\\d{4}")
/// flag_text: 닫는 `/` 뒤의 플래그 텍스트 (예: "gi")
/// 에러가 있으면 에러 메시지를 반환, 없으면 null.
pub fn validate(pattern: []const u8, flag_text: []const u8) ?[]const u8 {
    // 1. 플래그 검증
    if (flags.validate(flag_text) != null) {
        return "invalid regular expression flags";
    }

    // 2. 패턴 검증
    const parsed_flags = flags.parse(flag_text);
    const Validator = parser.PatternParser(false);
    var validator = Validator.init(pattern, parsed_flags);
    if (validator.validate()) |err| {
        return err;
    }

    return null;
}

test {
    _ = flags;
    _ = diagnostics;
    _ = parser;
}
