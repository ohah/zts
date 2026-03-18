//! ZTS Code Generator
//!
//! 변환된 AST를 JavaScript 문자열로 출력한다.
//! 소스맵은 추후 추가 예정.
//!
//! 설계:
//! - AST를 순회하며 JS 문자열을 ArrayList(u8)에 직접 출력
//! - switch 기반 (transformer와 동일 패턴)
//! - 원본 소스의 span을 참조하여 식별자/리터럴 텍스트를 zero-copy 출력

pub const codegen = @import("codegen.zig");
pub const Codegen = codegen.Codegen;

test {
    _ = codegen;
}
