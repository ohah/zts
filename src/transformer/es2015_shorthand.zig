//! ES2015 다운레벨링: shorthand property
//!
//! --target < es2015 일 때 활성화.
//! { x, y } → { x: x, y: y }
//! { method() {} } → { method: function() {} }
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-object-initialiser (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/shorthand_property.rs (~41줄)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Shorthand(comptime _: type) type {
    return struct {
        // TODO: lowerShorthandProperty
    };
}

test "ES2015 shorthand module compiles" {
    _ = ES2015Shorthand;
}
