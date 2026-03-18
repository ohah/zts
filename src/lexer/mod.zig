//! ZTS Lexer
//!
//! JavaScript / TypeScript / JSX / Flow 소스 코드를 토큰으로 분리한다.
//! 파서가 렉서를 호출하는 방식으로 연동 (D036).

pub const token = @import("token.zig");

pub const Token = token.Token;
pub const Kind = token.Kind;
pub const Span = token.Span;
pub const keywords = token.keywords;

test {
    _ = token;
}
