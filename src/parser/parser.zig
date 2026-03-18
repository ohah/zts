//! ZTS Parser
//!
//! 토큰 스트림을 AST로 변환하는 재귀 하강(recursive descent) 파서.
//! 2패스 설계: parse → visit (D040).
//! 에러 복구: 다중 에러 수집 (D039).
//!
//! 참고:
//! - references/bun/src/js_parser.zig
//! - references/oxc/crates/oxc_parser/src/

const std = @import("std");
const Scanner = @import("../lexer/scanner.zig").Scanner;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;

/// 파서 에러 하나.
pub const ParseError = struct {
    span: Span,
    message: []const u8,
};

/// 재귀 하강 파서.
/// Scanner에서 토큰을 하나씩 읽어 AST를 구축한다.
pub const Parser = struct {
    /// 렉서 (토큰 공급)
    scanner: *Scanner,

    /// AST 저장소
    ast: Ast,

    /// 수집된 에러 목록 (D039: 다중 에러)
    errors: std.ArrayList(ParseError),

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) Parser {
        return .{
            .scanner = scanner,
            .ast = Ast.init(allocator, scanner.source),
            .errors = std.ArrayList(ParseError).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        self.errors.deinit();
    }

    // ================================================================
    // 토큰 접근 헬퍼
    // ================================================================

    /// 현재 토큰의 Kind.
    fn current(self: *const Parser) Kind {
        return self.scanner.token.kind;
    }

    /// 현재 토큰의 Span.
    fn currentSpan(self: *const Parser) Span {
        return self.scanner.token.span;
    }

    /// 다음 토큰으로 전진.
    fn advance(self: *Parser) void {
        self.scanner.next();
    }

    /// 현재 토큰이 expected이면 소비하고 true, 아니면 false.
    fn eat(self: *Parser, expected: Kind) bool {
        if (self.current() == expected) {
            self.advance();
            return true;
        }
        return false;
    }

    /// 현재 토큰이 expected이면 소비, 아니면 에러 추가.
    fn expect(self: *Parser, expected: Kind) void {
        if (!self.eat(expected)) {
            self.addError(self.currentSpan(), expected.symbol());
        }
    }

    /// 에러를 추가한다.
    fn addError(self: *Parser, span: Span, expected: []const u8) void {
        self.errors.append(.{
            .span = span,
            .message = expected,
        }) catch {};
    }

    /// 현재 토큰의 소스 텍스트.
    fn tokenText(self: *const Parser) []const u8 {
        return self.scanner.tokenText();
    }

    // ================================================================
    // 프로그램 파싱 (최상위)
    // ================================================================

    /// 소스 전체를 파싱하여 AST를 반환한다.
    pub fn parse(self: *Parser) !NodeIndex {
        self.advance(); // 첫 토큰 로드

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        while (self.current() != .eof) {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) {
                try stmts.append(stmt);
            }
        }

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .program,
            .span = .{ .start = 0, .end = @intCast(self.scanner.source.len) },
            .data = .{ .list = list },
        });
    }

    // ================================================================
    // Statement 파싱
    // ================================================================

    fn parseStatement(self: *Parser) !NodeIndex {
        return switch (self.current()) {
            .l_curly => self.parseBlockStatement(),
            .semicolon => self.parseEmptyStatement(),
            .kw_var, .kw_let, .kw_const => self.parseVariableDeclaration(),
            .kw_return => self.parseReturnStatement(),
            .kw_if => self.parseIfStatement(),
            .kw_while => self.parseWhileStatement(),
            .kw_for => self.parseForStatement(),
            .kw_break => self.parseBreakStatement(),
            .kw_continue => self.parseContinueStatement(),
            .kw_throw => self.parseThrowStatement(),
            .kw_debugger => self.parseDebuggerStatement(),
            .kw_function => self.parseFunctionDeclaration(),
            else => self.parseExpressionStatement(),
        };
    }

    fn parseBlockStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        while (self.current() != .r_curly and self.current() != .eof) {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try stmts.append(stmt);
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseEmptyStatement(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        self.advance(); // skip ;
        return try self.ast.addNode(.{
            .tag = .empty_statement,
            .span = span,
            .data = .{ .none = {} },
        });
    }

    fn parseExpressionStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        const expr = try self.parseExpression();
        const end = self.currentSpan().end;
        _ = self.eat(.semicolon); // 세미콜론은 선택적 (ASI)
        return try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = expr } },
        });
    }

    fn parseVariableDeclaration(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        const kind_flags: u16 = switch (self.current()) {
            .kw_var => 0,
            .kw_let => 1,
            .kw_const => 2,
            else => 0,
        };
        self.advance(); // skip var/let/const

        var declarators = std.ArrayList(NodeIndex).init(self.allocator);
        defer declarators.deinit();

        while (true) {
            const decl = try self.parseVariableDeclarator();
            try declarators.append(decl);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);

        const list = try self.ast.addNodeList(declarators.items);
        return try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = .{ .start = start, .end = end },
            .data = .{ .binary = .{ .left = @enumFromInt(list.start), .right = @enumFromInt(list.len), .flags = kind_flags } },
        });
    }

    fn parseVariableDeclarator(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        // 바인딩 패턴 (간단히 식별자만 우선 지원)
        const name = try self.parseBindingIdentifier();

        // 이니셜라이저
        var init_expr = NodeIndex.none;
        if (self.eat(.eq)) {
            init_expr = try self.parseAssignmentExpression();
        }

        return try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = init_expr } },
        });
    }

    fn parseReturnStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'return'

        var arg = NodeIndex.none;
        if (self.current() != .semicolon and self.current() != .eof and
            self.current() != .r_curly and !self.scanner.token.has_newline_before)
        {
            arg = try self.parseExpression();
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .return_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = arg } },
        });
    }

    fn parseIfStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'if'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        const consequent = try self.parseStatement();

        var alternate = NodeIndex.none;
        if (self.eat(.kw_else)) {
            alternate = try self.parseStatement();
        }

        return try self.ast.addNode(.{
            .tag = .if_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = test_expr, .b = consequent, .c = alternate } },
        });
    }

    fn parseWhileStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'while'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseStatement();

        return try self.ast.addNode(.{
            .tag = .while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body } },
        });
    }

    fn parseForStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'for'
        self.expect(.l_paren);

        // 간단한 for(;;) 파싱 — for-in/for-of는 추후 PR
        var init_expr = NodeIndex.none;
        if (self.current() != .semicolon) {
            if (self.current() == .kw_var or self.current() == .kw_let or self.current() == .kw_const) {
                init_expr = try self.parseVariableDeclaration();
            } else {
                init_expr = try self.parseExpression();
                _ = self.eat(.semicolon);
            }
        } else {
            self.advance(); // skip ;
        }

        var test_expr = NodeIndex.none;
        if (self.current() != .semicolon) {
            test_expr = try self.parseExpression();
        }
        _ = self.eat(.semicolon);

        var update_expr = NodeIndex.none;
        if (self.current() != .r_paren) {
            update_expr = try self.parseExpression();
        }
        self.expect(.r_paren);

        const body = try self.parseStatement();

        // for는 4개 자식 → extra_data에 저장
        const extra_start = try self.ast.addExtra(@intFromEnum(init_expr));
        _ = try self.ast.addExtra(@intFromEnum(test_expr));
        _ = try self.ast.addExtra(@intFromEnum(update_expr));
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .for_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseBreakStatement(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        self.advance();
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{ .tag = .break_statement, .span = span, .data = .{ .none = {} } });
    }

    fn parseContinueStatement(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        self.advance();
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{ .tag = .continue_statement, .span = span, .data = .{ .none = {} } });
    }

    fn parseThrowStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'throw'
        const arg = try self.parseExpression();
        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = .throw_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = arg } },
        });
    }

    fn parseDebuggerStatement(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        self.advance();
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{ .tag = .debugger_statement, .span = span, .data = .{ .none = {} } });
    }

    fn parseFunctionDeclaration(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // 함수 이름
        const name = try self.parseBindingIdentifier();

        // 파라미터
        self.expect(.l_paren);
        var params = std.ArrayList(NodeIndex).init(self.allocator);
        defer params.deinit();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try params.append(param);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);

        // 본문
        const body = try self.parseBlockStatement();

        const param_list = try self.ast.addNodeList(params.items);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // ================================================================
    // Expression 파싱 (Pratt parser / precedence climbing)
    // ================================================================

    fn parseExpression(self: *Parser) !NodeIndex {
        return self.parseAssignmentExpression();
    }

    fn parseAssignmentExpression(self: *Parser) !NodeIndex {
        const left = try self.parseConditionalExpression();

        if (self.current().isAssignment()) {
            const op_span = self.currentSpan();
            const flags: u16 = @intFromEnum(self.current());
            self.advance();
            const right = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = .{ .start = op_span.start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = flags } },
            });
        }

        return left;
    }

    fn parseConditionalExpression(self: *Parser) !NodeIndex {
        const expr = try self.parseBinaryExpression(0);

        if (self.eat(.question)) {
            const consequent = try self.parseAssignmentExpression();
            self.expect(.colon);
            const alternate = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = .{ .start = 0, .end = self.currentSpan().start },
                .data = .{ .ternary = .{ .a = expr, .b = consequent, .c = alternate } },
            });
        }

        return expr;
    }

    /// 이항 연산자를 precedence climbing으로 파싱.
    fn parseBinaryExpression(self: *Parser, min_prec: u8) !NodeIndex {
        var left = try self.parseUnaryExpression();

        while (true) {
            const prec = getBinaryPrecedence(self.current());
            if (prec == 0 or prec <= min_prec) break;

            const op_kind = self.current();
            const is_logical = (op_kind == .amp2 or op_kind == .pipe2 or op_kind == .question2);
            self.advance();

            const right = try self.parseBinaryExpression(prec);
            const tag: Tag = if (is_logical) .logical_expression else .binary_expression;

            left = try self.ast.addNode(.{
                .tag = tag,
                .span = .{ .start = 0, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = @intFromEnum(op_kind) } },
            });
        }

        return left;
    }

    fn parseUnaryExpression(self: *Parser) !NodeIndex {
        const kind = self.current();
        switch (kind) {
            .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
                const start = self.currentSpan().start;
                self.advance();
                const operand = try self.parseUnaryExpression();
                return try self.ast.addNode(.{
                    .tag = .unary_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = @intFromEnum(kind) } },
                });
            },
            .plus2, .minus2 => {
                const start = self.currentSpan().start;
                self.advance();
                const operand = try self.parseUnaryExpression();
                return try self.ast.addNode(.{
                    .tag = .update_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = @intFromEnum(kind) } },
                });
            },
            .kw_await => {
                const start = self.currentSpan().start;
                self.advance();
                const operand = try self.parseUnaryExpression();
                return try self.ast.addNode(.{
                    .tag = .await_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand } },
                });
            },
            else => return self.parsePostfixExpression(),
        }
    }

    fn parsePostfixExpression(self: *Parser) !NodeIndex {
        var expr = try self.parseCallExpression();

        // 후위 ++/--
        if ((self.current() == .plus2 or self.current() == .minus2) and
            !self.scanner.token.has_newline_before)
        {
            const kind = self.current();
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .update_expression,
                .span = .{ .start = 0, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = @intFromEnum(kind) | 0x100 } }, // 0x100 = postfix
            });
        }

        return expr;
    }

    fn parseCallExpression(self: *Parser) !NodeIndex {
        var expr = try self.parsePrimaryExpression();

        while (true) {
            switch (self.current()) {
                .l_paren => {
                    // 함수 호출
                    self.advance();
                    var args = std.ArrayList(NodeIndex).init(self.allocator);
                    defer args.deinit();
                    while (self.current() != .r_paren and self.current() != .eof) {
                        const arg = try self.parseAssignmentExpression();
                        try args.append(arg);
                        if (!self.eat(.comma)) break;
                    }
                    self.expect(.r_paren);

                    const arg_list = try self.ast.addNodeList(args.items);
                    expr = try self.ast.addNode(.{
                        .tag = .call_expression,
                        .span = .{ .start = 0, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                    });
                },
                .dot => {
                    // 멤버 접근: a.b
                    self.advance();
                    const prop = try self.parseIdentifierName();
                    expr = try self.ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = .{ .start = 0, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop } },
                    });
                },
                .l_bracket => {
                    // 계산된 멤버 접근: a[b]
                    self.advance();
                    const prop = try self.parseExpression();
                    self.expect(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = 0, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop } },
                    });
                },
                else => break,
            }
        }

        return expr;
    }

    fn parsePrimaryExpression(self: *Parser) !NodeIndex {
        const span = self.currentSpan();

        switch (self.current()) {
            .identifier => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .numeric_literal,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
            .string_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .kw_true, .kw_false => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .boolean_literal,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
            .kw_null => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .null_literal,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
            .kw_this => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
            .l_paren => {
                // 괄호 표현식
                self.advance();
                const expr = try self.parseExpression();
                self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr } },
                });
            },
            .l_bracket => {
                // 배열 리터럴
                return self.parseArrayExpression();
            },
            .l_curly => {
                // 객체 리터럴
                return self.parseObjectExpression();
            },
            else => {
                // 에러 복구: 알 수 없는 토큰 → 에러 노드 생성 후 건너뜀
                self.addError(span, "expression expected");
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .invalid,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
        }
    }

    fn parseArrayExpression(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        var elements = std.ArrayList(NodeIndex).init(self.allocator);
        defer elements.deinit();

        while (self.current() != .r_bracket and self.current() != .eof) {
            if (self.current() == .comma) {
                // elision (빈 슬롯)
                self.advance();
                continue;
            }
            const elem = try self.parseAssignmentExpression();
            try elements.append(elem);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_bracket);

        const list = try self.ast.addNodeList(elements.items);
        return try self.ast.addNode(.{
            .tag = .array_expression,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseObjectExpression(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        var props = std.ArrayList(NodeIndex).init(self.allocator);
        defer props.deinit();

        while (self.current() != .r_curly and self.current() != .eof) {
            const prop = try self.parseObjectProperty();
            try props.append(prop);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(props.items);
        return try self.ast.addNode(.{
            .tag = .object_expression,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseObjectProperty(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        const key = try self.parsePrimaryExpression(); // 간단히 expression으로 키 파싱

        var value = NodeIndex.none;
        if (self.eat(.colon)) {
            value = try self.parseAssignmentExpression();
        }

        return try self.ast.addNode(.{
            .tag = .object_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value } },
        });
    }

    fn parseBindingIdentifier(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .identifier or self.current().isKeyword()) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .binding_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "identifier expected");
        return NodeIndex.none;
    }

    fn parseIdentifierName(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .identifier or self.current().isKeyword()) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "identifier expected");
        self.advance();
        return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = {} } });
    }

    // ================================================================
    // 연산자 우선순위
    // ================================================================

    fn getBinaryPrecedence(kind: Kind) u8 {
        return switch (kind) {
            .pipe2 => 1, // ||
            .question2 => 1, // ??
            .amp2 => 2, // &&
            .pipe => 3, // |
            .caret => 4, // ^
            .amp => 5, // &
            .eq2, .neq, .eq3, .neq2 => 6, // == != === !==
            .l_angle, .r_angle, .lt_eq, .gt_eq, .kw_instanceof, .kw_in => 7, // < > <= >= instanceof in
            .shift_left, .shift_right, .shift_right3 => 8, // << >> >>>
            .plus, .minus => 9, // + -
            .star, .slash, .percent => 10, // * / %
            .star2 => 11, // ** (우결합)
            else => 0, // 이항 연산자 아님
        };
    }
};

// ============================================================
// Tests
// ============================================================

test "Parser: empty program" {
    var scanner = Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
}

test "Parser: variable declaration" {
    var scanner = Scanner.init(std.testing.allocator, "const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: binary expression" {
    var scanner = Scanner.init(std.testing.allocator, "1 + 2 * 3;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: if statement" {
    var scanner = Scanner.init(std.testing.allocator, "if (x) { return 1; } else { return 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function declaration" {
    var scanner = Scanner.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: call expression" {
    var scanner = Scanner.init(std.testing.allocator, "foo(1, 2, 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: member access" {
    var scanner = Scanner.init(std.testing.allocator, "a.b.c;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array and object literals" {
    var scanner = Scanner.init(std.testing.allocator, "[1, 2, 3];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: error recovery" {
    var scanner = Scanner.init(std.testing.allocator, "@@@;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    // 에러가 수집되지만 파싱은 계속됨
    try std.testing.expect(parser.errors.items.len > 0);
}
