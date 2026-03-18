//! ZTS — Zig TypeScript Transpiler
//!
//! 라이브러리 엔트리포인트. 모든 공개 모듈을 여기서 re-export한다.

const std = @import("std");

pub const lexer = @import("lexer/mod.zig");
pub const parser = @import("parser/mod.zig");
pub const transformer = @import("transformer/mod.zig");
pub const codegen = @import("codegen/mod.zig");
pub const test262 = @import("test262/mod.zig");

test {
    _ = lexer;
    _ = test262;
}
