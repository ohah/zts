//! ES2015 다운레벨링: spread element
//!
//! --target < es2015 일 때 활성화.
//! f(...arr) → f.apply(null, arr)
//! [...arr, x] → [].concat(arr, [x])
//! new C(...args) → new (Function.prototype.bind.apply(C, [null].concat(args)))
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-argument-lists (ES2015, spread)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/spread.rs (~545줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Spread(comptime _: type) type {
    return struct {
        // TODO: lowerSpreadCall
        // TODO: lowerSpreadArray
        // TODO: lowerSpreadNew
    };
}

test "ES2015 spread module compiles" {
    _ = ES2015Spread;
}
