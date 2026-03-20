//! RegExp 검증 에러 메시지.

/// RegExp 검증 에러.
pub const Error = struct {
    /// 에러 메시지 (정적 문자열)
    message: []const u8,
    /// 에러 위치 (패턴/플래그 내의 byte offset, 0-based)
    offset: u32 = 0,
};
