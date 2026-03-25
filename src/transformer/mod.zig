//! ZTS Transformer
//!
//! 원본 AST를 순회하면서 새 AST를 빌드한다 (D041).
//! TypeScript 전용 노드를 제거하고, TS 구문을 JS로 변환한다.
//!
//! 설계:
//! - 새 AST 생성 방식 (D041: oxc/SWC 방식)
//! - Switch 기반 visitor + comptime 보조 (D042: esbuild/Bun 방식)
//! - 단일 패스, 변환 우선순위로 순서 제어 (D043)
//!
//! 참고:
//! - references/oxc/crates/oxc_transformer/src/
//! - references/esbuild/internal/js_parser/js_parser.go

pub const transformer = @import("transformer.zig");
pub const Transformer = transformer.Transformer;
pub const DefineEntry = transformer.DefineEntry;
pub const TransformOptions = transformer.TransformOptions;

test {
    _ = transformer;
}
