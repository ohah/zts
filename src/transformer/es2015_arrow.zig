//! ES2015 다운레벨링: arrow function
//!
//! --target < es2015 일 때 활성화.
//! () => expr → function() { return expr; }
//! () => { stmts } → function() { stmts }
//! this 참조 → var _this = this; ... _this
//! arguments 참조 → var _arguments = arguments;
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-arrow-function-definitions (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/arrow.rs (~253줄)
//! - oxc: crates/oxc_transformer/src/common/arrow_function_converter.rs
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Arrow(comptime _: type) type {
    return struct {
        // TODO: lowerArrowFunction
        // TODO: captureThis
    };
}

test "ES2015 arrow module compiles" {
    _ = ES2015Arrow;
}
