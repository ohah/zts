//! ES2015 다운레벨링: let/const → var
//!
//! --target < es2015 일 때 활성화.
//! let x = 1 → var x = 1
//! const y = 2 → var y = 2
//! for (let i = 0; ...) → TDZ 에뮬레이션 (IIFE 래핑 필요 시)
//!
//! TDZ (Temporal Dead Zone) 에뮬레이션:
//! - 루프 내 클로저가 let 변수를 캡처하는 경우 IIFE로 감싸야 함
//! - 단순 선언은 var로 교체만 하면 됨
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-let-and-const-declarations (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/block_scoping/ (~1404줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015BlockScoping(comptime _: type) type {
    return struct {
        // TODO: lowerLetConst
        // TODO: wrapLoopBodyForTDZ
    };
}

test "ES2015 block scoping module compiles" {
    _ = ES2015BlockScoping;
}
