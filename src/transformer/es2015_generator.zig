//! ES2015 다운레벨링: generator function
//!
//! --target < es2015 일 때 활성화.
//! function* gen() { yield 1; yield 2; }
//! → function gen() { return __generator(function(state) { switch(state) { ... } }); }
//!
//! generator는 상태 머신으로 변환된다.
//! 각 yield 지점이 상태 전이(state transition)가 되고,
//! switch 문으로 상태별 실행 흐름을 제어한다.
//!
//! 런타임 헬퍼: __generator (상태 머신 실행기)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-generator-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/generator.rs (~3778줄)
//! - TypeScript: src/compiler/transformers/generators.ts (SWC 기반)
//! - esbuild: 미지원 (generator 다운레벨링 없음)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Generator(comptime _: type) type {
    return struct {
        // TODO: lowerGeneratorFunction
        // TODO: buildStateMachine
        // TODO: transformYieldExpression
    };
}

test "ES2015 generator module compiles" {
    _ = ES2015Generator;
}
