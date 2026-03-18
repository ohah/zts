//! ZTS Parser
//!
//! 토큰 스트림을 AST로 변환한다.
//! Phase 2에서 구현.

pub const ast = @import("ast.zig");

pub const Ast = ast.Ast;
pub const Node = ast.Node;
pub const Tag = ast.Node.Tag;
pub const NodeIndex = ast.NodeIndex;
pub const NodeList = ast.NodeList;

test {
    _ = ast;
}
