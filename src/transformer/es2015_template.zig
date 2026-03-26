//! ES2015 다운레벨링: template literal
//!
//! --target < es2015 일 때 활성화.
//! `hello ${name}!` → "hello " + name + "!"
//! `${a}${b}` → "" + a + b
//! tagged`hello ${name}` → tag(["hello ", ""], name)
//!
//! 스펙:
//! - https://tc39.es/ecma262/#sec-template-literals (ES2015)
//!
//! 참고:
//! - SWC: crates/swc_ecma_compat_es2015/src/template_literal.rs (~400줄)
//! - esbuild: pkg/js_parser/js_parser_lower.go (template → concat)

const std = @import("std");
const ast_mod = @import("../parser/ast.zig");
const Node = ast_mod.Node;
const NodeIndex = ast_mod.NodeIndex;
const Tag = Node.Tag;
const token_mod = @import("../lexer/token.zig");
const Span = token_mod.Span;

pub fn ES2015Template(comptime _: type) type {
    return struct {
        // TODO: lowerTemplateLiteral
        // TODO: lowerTaggedTemplate
    };
}

test "ES2015 template module compiles" {
    _ = ES2015Template;
}
