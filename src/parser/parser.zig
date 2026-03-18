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

    /// 재사용 가능한 임시 버퍼 (리스트 수집용). 매 사용 시 clearRetainingCapacity.
    scratch: std.ArrayList(NodeIndex),

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) Parser {
        return .{
            .scanner = scanner,
            .ast = Ast.init(allocator, scanner.source),
            .errors = std.ArrayList(ParseError).init(allocator),
            .scratch = std.ArrayList(NodeIndex).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        self.errors.deinit();
        self.scratch.deinit();
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
        }) catch @panic("OOM: parser error list");
    }

    /// scratch 버퍼의 현재 위치를 저장한다. 중첩 사용 시 save/restore 패턴.
    /// 사용법:
    ///   const top = self.saveScratch();
    ///   // ... scratch에 append ...
    ///   const items = self.scratch.items[top..];
    ///   // ... items 사용 후 ...
    ///   self.restoreScratch(top);
    fn saveScratch(self: *const Parser) usize {
        return self.scratch.items.len;
    }

    fn restoreScratch(self: *Parser, top: usize) void {
        self.scratch.shrinkRetainingCapacity(top);
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
            .kw_do => self.parseDoWhileStatement(),
            .kw_for => self.parseForStatement(),
            .kw_switch => self.parseSwitchStatement(),
            .kw_break => self.parseSimpleStatement(.break_statement),
            .kw_continue => self.parseSimpleStatement(.continue_statement),
            .kw_throw => self.parseThrowStatement(),
            .kw_try => self.parseTryStatement(),
            .kw_debugger => self.parseSimpleStatement(.debugger_statement),
            .kw_async => self.parseAsyncStatement(),
            .kw_function => self.parseFunctionDeclaration(),
            .kw_class => self.parseClassDeclaration(),
            .kw_import => self.parseImportDeclaration(),
            .kw_export => self.parseExportDeclaration(),
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
        const kind_flags: u32 = switch (self.current()) {
            .kw_var => 0,
            .kw_let => 1,
            .kw_const => 2,
            else => 0,
        };
        self.advance(); // skip var/let/const

        const scratch_top = self.saveScratch();
        while (true) {
            const decl = try self.parseVariableDeclarator();
            try self.scratch.append(decl);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);

        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        // extra_data: [kind_flags, list.start, list.len]
        const extra_start = try self.ast.addExtra(kind_flags);
        _ = try self.ast.addExtra(list.start);
        _ = try self.ast.addExtra(list.len);

        return try self.ast.addNode(.{
            .tag = .variable_declaration,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseVariableDeclarator(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        // 바인딩 패턴 (identifier, [array], {object} destructuring)
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

    fn parseDoWhileStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'do'
        const body = try self.parseStatement();
        self.expect(.kw_while);
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .do_while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body } },
        });
    }

    fn parseForStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'for'
        self.expect(.l_paren);

        // for문의 init 부분 파싱
        // for(init; ...) or for(left in/of right)
        if (self.current() == .semicolon) {
            // for(; ...) — 빈 init
            self.advance();
            return self.parseForRest(start, NodeIndex.none);
        }

        if (self.current() == .kw_var or self.current() == .kw_let or self.current() == .kw_const) {
            const init_expr = try self.parseVariableDeclaration();
            // parseVariableDeclaration이 세미콜론을 소비했으면 for(;;)
            // 'in' 또는 'of'가 보이면 for-in/for-of
            if (self.current() == .kw_in) {
                return self.parseForIn(start, init_expr);
            }
            if (self.current() == .kw_of) {
                return self.parseForOf(start, init_expr);
            }
            return self.parseForRest(start, init_expr);
        }

        // 일반 표현식 init
        const init_expr = try self.parseExpression();
        if (self.current() == .kw_in) {
            return self.parseForIn(start, init_expr);
        }
        if (self.current() == .kw_of) {
            return self.parseForOf(start, init_expr);
        }
        _ = self.eat(.semicolon);
        return self.parseForRest(start, init_expr);
    }

    /// for(init; test; update) body — 나머지 파싱
    fn parseForRest(self: *Parser, start: u32, init_expr: NodeIndex) !NodeIndex {
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

    /// for(left in right) body
    fn parseForIn(self: *Parser, start: u32, left: NodeIndex) !NodeIndex {
        self.advance(); // skip 'in'
        const right = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseStatement();

        return try self.ast.addNode(.{
            .tag = .for_in_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// for(left of right) body
    fn parseForOf(self: *Parser, start: u32, left: NodeIndex) !NodeIndex {
        self.advance(); // skip 'of'
        const right = try self.parseAssignmentExpression();
        self.expect(.r_paren);
        const body = try self.parseStatement();

        return try self.ast.addNode(.{
            .tag = .for_of_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// break, continue, debugger 등 키워드 + 세미콜론만으로 구성된 단순 문.
    fn parseSimpleStatement(self: *Parser, tag: Tag) !NodeIndex {
        const span = self.currentSpan();
        self.advance();
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{ .tag = tag, .span = span, .data = .{ .none = {} } });
    }

    fn parseSwitchStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'switch'
        self.expect(.l_paren);
        const discriminant = try self.parseExpression();
        self.expect(.r_paren);
        self.expect(.l_curly);

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const case_node = try self.parseSwitchCase();
            try self.scratch.append(case_node);
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const cases = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(discriminant));
        _ = try self.ast.addExtra(cases.start);
        _ = try self.ast.addExtra(cases.len);

        return try self.ast.addNode(.{
            .tag = .switch_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseSwitchCase(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        var test_expr = NodeIndex.none;
        if (self.eat(.kw_case)) {
            test_expr = try self.parseExpression();
            self.expect(.colon);
        } else if (self.eat(.kw_default)) {
            self.expect(.colon);
        } else {
            const err_span = self.currentSpan();
            self.addError(err_span, "case or default expected");
            self.advance();
            return try self.ast.addNode(.{ .tag = .invalid, .span = err_span, .data = .{ .none = {} } });
        }

        // case 본문: 다음 case/default/} 전까지
        const body_top = self.saveScratch();
        while (self.current() != .kw_case and self.current() != .kw_default and
            self.current() != .r_curly and self.current() != .eof)
        {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try self.scratch.append(stmt);
        }

        const body = try self.ast.addNodeList(self.scratch.items[body_top..]);
        self.restoreScratch(body_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(test_expr));
        _ = try self.ast.addExtra(body.start);
        _ = try self.ast.addExtra(body.len);

        return try self.ast.addNode(.{
            .tag = .switch_case,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
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

    fn parseTryStatement(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'try'

        const block = try self.parseBlockStatement();

        // catch 절 (선택적)
        var handler = NodeIndex.none;
        if (self.current() == .kw_catch) {
            handler = try self.parseCatchClause();
        }

        // finally 절 (선택적)
        var finalizer = NodeIndex.none;
        if (self.eat(.kw_finally)) {
            finalizer = try self.parseBlockStatement();
        }

        // catch도 finally도 없으면 에러
        if (handler.isNone() and finalizer.isNone()) {
            self.addError(.{ .start = start, .end = self.currentSpan().start }, "catch or finally expected");
        }

        return try self.ast.addNode(.{
            .tag = .try_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = block, .b = handler, .c = finalizer } },
        });
    }

    fn parseCatchClause(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'catch'

        // catch 파라미터 (선택적 — ES2019 optional catch binding)
        var param = NodeIndex.none;
        if (self.eat(.l_paren)) {
            param = try self.parseBindingIdentifier();
            self.expect(.r_paren);
        }

        const body = try self.parseBlockStatement();

        return try self.ast.addNode(.{
            .tag = .catch_clause,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = param, .right = body } },
        });
    }

    fn parseFunctionDeclaration(self: *Parser) !NodeIndex {
        return self.parseFunctionDeclarationWithFlags(0);
    }

    fn parseFunctionDeclarationWithFlags(self: *Parser, extra_flags: u32) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // generator: function* name()
        var flags = extra_flags;
        if (self.eat(.star)) {
            flags |= 0x02; // generator flag
        }

        // 함수 이름
        const name = try self.parseBindingIdentifier();

        // 파라미터
        self.expect(.l_paren);
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);

        // 본문
        const body = try self.parseBlockStatement();

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));
        _ = try self.ast.addExtra(flags);

        return try self.ast.addNode(.{
            .tag = .function_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// async function / async arrow를 파싱한다.
    /// async 뒤에 function이 오면 async function declaration,
    /// 그 외는 expression statement로 처리.
    fn parseAsyncStatement(self: *Parser) !NodeIndex {
        const next = self.peekNextKind();
        if (next == .kw_function) {
            self.advance(); // skip 'async'
            return self.parseFunctionDeclarationWithFlags(0x01); // 0x01 = async flag
        }
        // async가 식별자인 경우 → expression statement
        return self.parseExpressionStatement();
    }

    fn parseFunctionExpression(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // 함수 이름 (선택적)
        var name = NodeIndex.none;
        if (self.current() == .identifier) {
            name = try self.parseBindingIdentifier();
        }

        self.expect(.l_paren);
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);

        const body = try self.parseBlockStatement();

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(param_list.start);
        _ = try self.ast.addExtra(param_list.len);
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .function_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseClassDeclaration(self: *Parser) !NodeIndex {
        return self.parseClass(.class_declaration);
    }

    fn parseClassExpression(self: *Parser) !NodeIndex {
        return self.parseClass(.class_expression);
    }

    /// class 선언/표현식을 파싱한다.
    fn parseClass(self: *Parser, tag: Tag) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'class'

        // 클래스 이름 (선언은 필수, 표현식은 선택)
        var name = NodeIndex.none;
        if (self.current() == .identifier) {
            name = try self.parseBindingIdentifier();
        }

        // extends 절 (선택)
        var super_class = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            super_class = try self.parseAssignmentExpression();
        }

        // 클래스 본문
        const body = try self.parseClassBody();

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(super_class));
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseClassBody(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            // 세미콜론 스킵 (클래스 본문에서 허용)
            if (self.current() == .semicolon) {
                self.advance();
                continue;
            }
            const member = try self.parseClassMember();
            if (!member.isNone()) try self.scratch.append(member);
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .class_body,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = members },
        });
    }

    fn parseClassMember(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        // static 키워드 (선택)
        // static은 멤버 이름으로도 사용 가능: class C { static() {} }
        // static 뒤에 {, (, = 가 오면 이름으로 취급
        var flags: u16 = 0;
        if (self.current() == .kw_static) {
            const next = self.peekNextKind();
            if (next == .l_curly) {
                // static { } — static block
                self.advance(); // skip 'static'
                const body = try self.parseBlockStatement();
                return try self.ast.addNode(.{
                    .tag = .static_block,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = body } },
                });
            }
            // static 뒤에 (나 = 가 오면 static은 메서드/프로퍼티 이름
            if (next != .l_paren and next != .eq and next != .semicolon) {
                flags |= 0x01; // static modifier
                self.advance();
            }
        }

        // get/set (선택)
        if (self.current() == .kw_get and self.peekNextKind() != .l_paren) {
            flags |= 0x02; // getter
            self.advance();
        } else if (self.current() == .kw_set and self.peekNextKind() != .l_paren) {
            flags |= 0x04; // setter
            self.advance();
        }

        // 키
        const key = try self.parsePropertyKey();

        // 메서드 (파라미터 리스트가 있으면)
        if (self.current() == .l_paren) {
            self.expect(.l_paren);
            const param_top = self.saveScratch();
            while (self.current() != .r_paren and self.current() != .eof) {
                const param = try self.parseBindingIdentifier();
                try self.scratch.append(param);
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_paren);

            const body = try self.parseBlockStatement();
            const param_list = try self.ast.addNodeList(self.scratch.items[param_top..]);
            self.restoreScratch(param_top);

            const extra_start = try self.ast.addExtra(@intFromEnum(key));
            _ = try self.ast.addExtra(param_list.start);
            _ = try self.ast.addExtra(param_list.len);
            _ = try self.ast.addExtra(@intFromEnum(body));

            _ = try self.ast.addExtra(flags);

            return try self.ast.addNode(.{
                .tag = .method_definition,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // 프로퍼티 (= 이니셜라이저)
        var init_val = NodeIndex.none;
        if (self.eat(.eq)) {
            init_val = try self.parseAssignmentExpression();
        }
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .property_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = init_val, .flags = flags } },
        });
    }

    /// 다음 토큰의 Kind를 미리 본다 (현재 토큰을 소비하지 않음).
    /// 간단한 1-lookahead. 비용이 있으므로 class member 파싱 등 제한적 사용.
    fn peekNextKind(self: *Parser) Kind {
        const saved_pos = self.scanner.current;
        const saved_start = self.scanner.start;
        const saved_token = self.scanner.token;
        const saved_line = self.scanner.line;
        const saved_line_start = self.scanner.line_start;
        const saved_brace_depth = self.scanner.brace_depth;
        const saved_prev_token = self.scanner.prev_token_kind;
        const saved_template_len = self.scanner.template_depth_stack.items.len;

        self.scanner.next();
        const next_kind = self.scanner.token.kind;

        self.scanner.current = saved_pos;
        self.scanner.start = saved_start;
        self.scanner.token = saved_token;
        self.scanner.line = saved_line;
        self.scanner.line_start = saved_line_start;
        self.scanner.brace_depth = saved_brace_depth;
        self.scanner.prev_token_kind = saved_prev_token;
        self.scanner.template_depth_stack.shrinkRetainingCapacity(saved_template_len);

        return next_kind;
    }

    // ================================================================
    // Import / Export 파싱
    // ================================================================

    fn parseImportDeclaration(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'import'

        // import "module" — side-effect import
        if (self.current() == .string_literal) {
            const source_node = try self.parseModuleSource();
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .import_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = source_node } },
            });
        }

        // import(...) — dynamic import는 expression. expression statement로 파싱.
        if (self.current() == .l_paren) {
            // import 키워드는 이미 advance()됨. parsePrimaryExpression에 위임하기 위해
            // 수동으로 import expression 생성.
            self.expect(.l_paren);
            const arg = try self.parseAssignmentExpression();
            self.expect(.r_paren);
            const import_expr = try self.ast.addNode(.{
                .tag = .import_expression,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = arg } },
            });
            // 후속 .then() 등의 member/call 체이닝 처리
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .expression_statement,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = import_expr } },
            });
        }

        // 스펙ifier 파싱
        const scratch_top = self.saveScratch();

        // default import: import foo from "module"
        var has_default = false;
        if (self.current() == .identifier) {
            const next = self.peekNextKind();
            if (next == .comma or next == .kw_from) {
                const spec_span = self.currentSpan();
                self.advance();
                const spec = try self.ast.addNode(.{
                    .tag = .import_default_specifier,
                    .span = spec_span,
                    .data = .{ .string_ref = spec_span },
                });
                try self.scratch.append(spec);
                has_default = true;

                if (self.eat(.comma)) {
                    // import default, { ... } from "module"
                    // import default, * as ns from "module"
                } else {
                    // import default from "module"
                    self.expect(.kw_from);
                    const source_node = try self.parseModuleSource();
                    _ = self.eat(.semicolon);

                    const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    self.restoreScratch(scratch_top);
                    const extra_start = try self.ast.addExtra(specifiers.start);
                    _ = try self.ast.addExtra(specifiers.len);
                    _ = try self.ast.addExtra(@intFromEnum(source_node));

                    return try self.ast.addNode(.{
                        .tag = .import_declaration,
                        .span = .{ .start = start, .end = self.currentSpan().start },
                        .data = .{ .extra = extra_start },
                    });
                }
            }
        }

        // namespace import: import * as ns from "module"
        if (self.current() == .star) {
            self.advance(); // skip *
            self.expect(.kw_as);
            const local_span = self.currentSpan();
            self.expect(.identifier);
            const spec = try self.ast.addNode(.{
                .tag = .import_namespace_specifier,
                .span = local_span,
                .data = .{ .string_ref = local_span },
            });
            try self.scratch.append(spec);
        }

        // named imports: import { a, b as c } from "module"
        if (self.current() == .l_curly) {
            self.advance(); // skip {
            while (self.current() != .r_curly and self.current() != .eof) {
                const spec = try self.parseImportSpecifier();
                try self.scratch.append(spec);
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_curly);
        }

        self.expect(.kw_from);
        const source_node = try self.parseModuleSource();
        _ = self.eat(.semicolon);

        const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const extra_start = try self.ast.addExtra(specifiers.start);
        _ = try self.ast.addExtra(specifiers.len);
        _ = try self.ast.addExtra(@intFromEnum(source_node));

        return try self.ast.addNode(.{
            .tag = .import_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseImportSpecifier(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        // imported name
        const imported = try self.parseIdentifierName();

        // as local
        var local = imported;
        if (self.eat(.kw_as)) {
            local = try self.parseIdentifierName();
        }

        return try self.ast.addNode(.{
            .tag = .import_specifier,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = imported, .right = local } },
        });
    }

    fn parseExportDeclaration(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'export'

        // export default
        if (self.eat(.kw_default)) {
            const decl = switch (self.current()) {
                .kw_function => try self.parseFunctionDeclaration(),
                .kw_class => try self.parseClassDeclaration(),
                else => blk: {
                    const expr = try self.parseAssignmentExpression();
                    _ = self.eat(.semicolon);
                    break :blk expr;
                },
            };
            return try self.ast.addNode(.{
                .tag = .export_default_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = decl } },
            });
        }

        // export * from "module" / export * as ns from "module"
        if (self.current() == .star) {
            self.advance(); // skip *
            var exported_name = NodeIndex.none;
            if (self.eat(.kw_as)) {
                const name_span = self.currentSpan();
                self.advance();
                exported_name = try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = name_span,
                    .data = .{ .string_ref = name_span },
                });
            }
            self.expect(.kw_from);
            const source_node = try self.parseModuleSource();
            _ = self.eat(.semicolon);

            return try self.ast.addNode(.{
                .tag = .export_all_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = exported_name, .right = source_node } },
            });
        }

        // export { a, b } / export { a } from "module"
        if (self.current() == .l_curly) {
            self.advance(); // skip {

            const scratch_top = self.saveScratch();
            while (self.current() != .r_curly and self.current() != .eof) {
                const spec = try self.parseExportSpecifier();
                try self.scratch.append(spec);
                if (!self.eat(.comma)) break;
            }
            self.expect(.r_curly);

            // re-export: export { a } from "module"
            var source_node = NodeIndex.none;
            if (self.eat(.kw_from)) {
                source_node = try self.parseModuleSource();
            }
            _ = self.eat(.semicolon);

            const specifiers = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
            self.restoreScratch(scratch_top);
            const extra_start = try self.ast.addExtra(specifiers.start);
            _ = try self.ast.addExtra(specifiers.len);
            _ = try self.ast.addExtra(@intFromEnum(source_node));

            return try self.ast.addNode(.{
                .tag = .export_named_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // export var/let/const/function/class
        const decl = try self.parseStatement();
        return try self.ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = decl } },
        });
    }

    fn parseExportSpecifier(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        const local = try self.parseIdentifierName();

        var exported = local;
        if (self.eat(.kw_as)) {
            exported = try self.parseIdentifierName();
        }

        return try self.ast.addNode(.{
            .tag = .export_specifier,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = local, .right = exported } },
        });
    }

    fn parseModuleSource(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .string_literal) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "module source string expected");
        return NodeIndex.none;
    }

    // ================================================================
    // Expression 파싱 (Pratt parser / precedence climbing)
    // ================================================================

    fn parseExpression(self: *Parser) !NodeIndex {
        return self.parseAssignmentExpression();
    }

    fn parseAssignmentExpression(self: *Parser) !NodeIndex {
        // 단일 식별자 + => → arrow function (간단한 형태: x => x + 1)
        if (self.current() == .identifier) {
            const id_span = self.currentSpan();
            const saved_pos = self.scanner.current;
            const saved_start = self.scanner.start;
            const saved_token = self.scanner.token;
            const saved_line = self.scanner.line;
            const saved_line_start = self.scanner.line_start;

            self.advance(); // skip identifier
            if (self.current() == .arrow) {
                // identifier => body
                self.advance(); // skip =>
                const param = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = id_span,
                    .data = .{ .string_ref = id_span },
                });
                const body = if (self.current() == .l_curly)
                    try self.parseBlockStatement()
                else
                    try self.parseAssignmentExpression();

                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = id_span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = param, .right = body } },
                });
            }

            // arrow가 아님 → 되돌리기
            self.scanner.current = saved_pos;
            self.scanner.start = saved_start;
            self.scanner.token = saved_token;
            self.scanner.line = saved_line;
            self.scanner.line_start = saved_line_start;
        }

        const left = try self.parseConditionalExpression();

        // => 를 만나면 arrow function (괄호 형태)
        // left가 parenthesized_expression이면 파라미터 리스트로 취급
        if (self.current() == .arrow) {
            const left_start = self.ast.getNode(left).span.start;
            self.advance(); // skip =>
            const body = if (self.current() == .l_curly)
                try self.parseBlockStatement()
            else
                try self.parseAssignmentExpression();

            return try self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = body } },
            });
        }

        if (self.current().isAssignment()) {
            const left_start = self.ast.getNode(left).span.start;
            const flags: u16 = @intFromEnum(self.current());
            self.advance();
            const right = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .assignment_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = flags } },
            });
        }

        return left;
    }

    fn parseConditionalExpression(self: *Parser) !NodeIndex {
        const expr = try self.parseBinaryExpression(0);

        if (self.eat(.question)) {
            const expr_start = self.ast.getNode(expr).span.start;
            const consequent = try self.parseAssignmentExpression();
            self.expect(.colon);
            const alternate = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
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

            const left_start = self.ast.getNode(left).span.start;
            const op_kind = self.current();
            const is_logical = (op_kind == .amp2 or op_kind == .pipe2 or op_kind == .question2);
            self.advance();

            // ** (star2)는 우결합: prec - 1로 재귀하여 같은 우선순위를 오른쪽에 허용
            const next_prec = if (op_kind == .star2) prec - 1 else prec;
            const right = try self.parseBinaryExpression(next_prec);
            const tag: Tag = if (is_logical) .logical_expression else .binary_expression;

            left = try self.ast.addNode(.{
                .tag = tag,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
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
            .kw_yield => {
                const start = self.currentSpan().start;
                self.advance();
                // yield* delegate
                var flags: u16 = 0;
                if (self.eat(.star)) {
                    flags = 1; // delegate
                }
                var operand = NodeIndex.none;
                // yield 뒤에 줄바꿈 없이 expression이 오면 yield의 인자
                if (!self.scanner.token.has_newline_before and
                    self.current() != .semicolon and self.current() != .r_curly and
                    self.current() != .r_paren and self.current() != .r_bracket and
                    self.current() != .colon and self.current() != .comma and
                    self.current() != .eof)
                {
                    operand = try self.parseAssignmentExpression();
                }
                return try self.ast.addNode(.{
                    .tag = .yield_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = flags } },
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
            const expr_start = self.ast.getNode(expr).span.start;
            const kind = self.current();
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .update_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = @intFromEnum(kind) | 0x100 } }, // 0x100 = postfix
            });
        }

        return expr;
    }

    fn parseCallExpression(self: *Parser) !NodeIndex {
        var expr = try self.parsePrimaryExpression();

        while (true) {
            const expr_start = self.ast.getNode(expr).span.start;
            switch (self.current()) {
                .l_paren => {
                    // 함수 호출
                    self.advance();
                    const scratch_top = self.saveScratch();
                    while (self.current() != .r_paren and self.current() != .eof) {
                        const arg = try self.parseSpreadOrAssignment();
                        try self.scratch.append(arg);
                        if (!self.eat(.comma)) break;
                    }
                    self.expect(.r_paren);

                    const arg_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
                    self.restoreScratch(scratch_top);
                    expr = try self.ast.addNode(.{
                        .tag = .call_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                    });
                },
                .dot => {
                    // 멤버 접근: a.b
                    self.advance();
                    const prop = try self.parseIdentifierName();
                    expr = try self.ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
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
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
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
            .kw_class => return self.parseClassExpression(),
            .kw_function => return self.parseFunctionExpression(),
            .kw_import => {
                // dynamic import: import("module")
                self.advance(); // skip 'import'
                self.expect(.l_paren);
                const arg = try self.parseAssignmentExpression();
                self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .import_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = arg } },
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
            const elem = try self.parseSpreadOrAssignment();
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

        // 키: identifier, string, number, 또는 computed [expr]
        const key = try self.parsePropertyKey();

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

    /// 바인딩 패턴을 파싱한다: identifier, [destructuring], {destructuring}
    fn parseBindingPattern(self: *Parser) !NodeIndex {
        switch (self.current()) {
            .identifier => {
                const span = self.currentSpan();
                self.advance();
                const node = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
                // default value: pattern = expr
                if (self.eat(.eq)) {
                    const default_val = try self.parseAssignmentExpression();
                    return try self.ast.addNode(.{
                        .tag = .assignment_pattern,
                        .span = .{ .start = span.start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = node, .right = default_val } },
                    });
                }
                return node;
            },
            .l_bracket => return self.parseArrayPattern(),
            .l_curly => return self.parseObjectPattern(),
            else => {
                // 키워드도 바인딩 이름으로 사용 가능한 경우 (let, yield 등)
                if (self.current().isKeyword()) {
                    const span = self.currentSpan();
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                self.addError(self.currentSpan(), "binding pattern expected");
                return NodeIndex.none;
            },
        }
    }

    /// 하위 호환: 식별자만 필요한 곳에서 호출
    fn parseBindingIdentifier(self: *Parser) !NodeIndex {
        return self.parseBindingPattern();
    }

    fn parseArrayPattern(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        const scratch_top = self.saveScratch();
        while (self.current() != .r_bracket and self.current() != .eof) {
            if (self.current() == .comma) {
                // elision (빈 슬롯) — placeholder 노드 추가
                const hole_span = self.currentSpan();
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .empty_statement, // 빈 슬롯 표현용
                    .span = hole_span,
                    .data = .{ .none = {} },
                }));
                self.advance();
                continue;
            }
            if (self.current() == .dot3) {
                // rest element: ...pattern
                const rest_start = self.currentSpan().start;
                self.advance(); // skip ...
                const rest_arg = try self.parseBindingPattern();
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg } },
                });
                try self.scratch.append(rest);
                break; // rest는 항상 마지막
            }
            const elem = try self.parseBindingPattern();
            if (!elem.isNone()) try self.scratch.append(elem);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_bracket);

        const elements = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .array_pattern,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = elements },
        });
    }

    fn parseObjectPattern(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            if (self.current() == .dot3) {
                // rest element: ...pattern
                const rest_start = self.currentSpan().start;
                self.advance(); // skip ...
                const rest_arg = try self.parseBindingPattern();
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg } },
                });
                try self.scratch.append(rest);
                break;
            }

            const prop = try self.parseBindingProperty();
            if (!prop.isNone()) try self.scratch.append(prop);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const props = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .object_pattern,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = props },
        });
    }

    fn parseBindingProperty(self: *Parser) !NodeIndex {
        const start = self.currentSpan().start;

        // shorthand: { x } = { x: x } 또는 { x = defaultVal }
        if (self.current() == .identifier) {
            const id_span = self.currentSpan();
            const next = self.peekNextKind();
            if (next == .comma or next == .r_curly or next == .eq) {
                // shorthand property
                self.advance();
                const key = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = id_span,
                    .data = .{ .string_ref = id_span },
                });
                var value = key;
                // default value
                if (self.eat(.eq)) {
                    const default_val = try self.parseAssignmentExpression();
                    value = try self.ast.addNode(.{
                        .tag = .assignment_pattern,
                        .span = .{ .start = id_span.start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = key, .right = default_val } },
                    });
                }
                return try self.ast.addNode(.{
                    .tag = .binding_property,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = key, .right = value } },
                });
            }
        }

        // key: pattern = default
        const key = try self.parsePropertyKey();
        self.expect(.colon);
        var value = try self.parseBindingPattern();

        // { x: pattern = defaultValue } 형태
        if (self.eat(.eq)) {
            const default_val = try self.parseAssignmentExpression();
            value = try self.ast.addNode(.{
                .tag = .assignment_pattern,
                .span = .{ .start = self.ast.getNode(value).span.start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = value, .right = default_val } },
            });
        }

        return try self.ast.addNode(.{
            .tag = .binding_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value } },
        });
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

    /// 객체 프로퍼티 키를 파싱한다.
    /// 허용: identifier, string literal, numeric literal, computed [expr].
    /// spread (...expr) 또는 assignment expression을 파싱. ...가 있으면 spread_element로 감싼다.
    fn parseSpreadOrAssignment(self: *Parser) !NodeIndex {
        if (self.current() == .dot3) {
            const start = self.currentSpan().start;
            self.advance(); // skip ...
            const arg = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = arg } },
            });
        }
        return self.parseAssignmentExpression();
    }

    fn parsePropertyKey(self: *Parser) !NodeIndex {
        const span = self.currentSpan();
        switch (self.current()) {
            .identifier, .kw_get, .kw_set, .kw_async, .kw_static => {
                // 키워드도 프로퍼티 키로 사용 가능 (get, set 등)
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
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
            .decimal, .float, .hex, .octal, .binary, .positive_exponential, .negative_exponential => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .numeric_literal,
                    .span = span,
                    .data = .{ .none = {} },
                });
            },
            .l_bracket => {
                // computed property: [expr]
                self.advance();
                const expr = try self.parseAssignmentExpression();
                self.expect(.r_bracket);
                return try self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr } },
                });
            },
            else => {
                // 다른 키워드도 프로퍼티 키로 허용 (class, return 등)
                if (self.current().isKeyword()) {
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                self.addError(span, "property key expected");
                self.advance();
                return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = {} } });
            },
        }
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
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: do-while statement" {
    var scanner = Scanner.init(std.testing.allocator, "do { x++; } while (x < 10);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-in statement" {
    var scanner = Scanner.init(std.testing.allocator, "for (var key in obj) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-of statement" {
    var scanner = Scanner.init(std.testing.allocator, "for (const item of arr) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch statement" {
    var scanner = Scanner.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1: break;
        \\  case 2: return 2;
        \\  default: return 0;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for with empty parts" {
    var scanner = Scanner.init(std.testing.allocator, "for (;;) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch with var in case body (scratch nesting)" {
    // 이 테스트는 scratch save/restore가 올바르게 동작하는지 검증한다.
    // case 본문에 var 선언이 있으면 scratch를 중첩 사용하게 되는데,
    // save/restore 없이 clearRetainingCapacity를 쓰면 이전 case가 사라진다.
    var scanner = Scanner.init(std.testing.allocator,
        \\switch (x) {
        \\  case 1:
        \\    var a = 1;
        \\    break;
        \\  case 2:
        \\    var b = 2;
        \\    break;
        \\  default:
        \\    break;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested call in var initializer (scratch nesting)" {
    // var x = foo(bar(1, 2), 3); — 중첩 호출에서 scratch가 안전한지 검증
    var scanner = Scanner.init(std.testing.allocator, "var x = foo(bar(1, 2), 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-finally" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch-finally" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try without catch or finally is error" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional catch binding (ES2019)" {
    var scanner = Scanner.init(std.testing.allocator, "try { foo(); } catch { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (simple)" {
    var scanner = Scanner.init(std.testing.allocator, "const f = x => x + 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (parenthesized)" {
    var scanner = Scanner.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function with block body" {
    var scanner = Scanner.init(std.testing.allocator, "const f = (x) => { return x * 2; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in array" {
    var scanner = Scanner.init(std.testing.allocator, "[1, ...arr, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in call" {
    var scanner = Scanner.init(std.testing.allocator, "foo(...args);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class declaration" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  constructor(x) { this.x = x; }
        \\  getX() { return this.x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with extends" {
    var scanner = Scanner.init(std.testing.allocator, "class Bar extends Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with static method and property" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Config {
        \\  static defaultValue = 42;
        \\  static create() { return 1; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class expression" {
    var scanner = Scanner.init(std.testing.allocator, "const Foo = class { bar() { } };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function expression" {
    var scanner = Scanner.init(std.testing.allocator, "const f = function(x) { return x; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const [a, b, c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: object destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const { x, y } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with default values" {
    var scanner = Scanner.init(std.testing.allocator, "const [a = 1, b = 2] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested destructuring" {
    var scanner = Scanner.init(std.testing.allocator, "const { a: { b } } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with rest" {
    var scanner = Scanner.init(std.testing.allocator, "const [first, ...rest] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function with destructuring params" {
    var scanner = Scanner.init(std.testing.allocator, "function foo({ x, y }, [a, b]) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// Import / Export tests
// ============================================================

test "Parser: import side-effect" {
    var scanner = Scanner.init(std.testing.allocator, "import 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default" {
    var scanner = Scanner.init(std.testing.allocator, "import foo from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import named" {
    var scanner = Scanner.init(std.testing.allocator, "import { a, b as c } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import namespace" {
    var scanner = Scanner.init(std.testing.allocator, "import * as ns from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default + named" {
    var scanner = Scanner.init(std.testing.allocator, "import React, { useState } from 'react';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default" {
    var scanner = Scanner.init(std.testing.allocator, "export default 42;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named" {
    var scanner = Scanner.init(std.testing.allocator, "export { a, b as c };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export declaration" {
    var scanner = Scanner.init(std.testing.allocator, "export const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export all re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export * from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export { foo } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default function" {
    var scanner = Scanner.init(std.testing.allocator, "export default function foo() { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: dynamic import expression" {
    var scanner = Scanner.init(std.testing.allocator, "const m = import('module');");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async function declaration" {
    var scanner = Scanner.init(std.testing.allocator, "async function fetchData() { return await fetch(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: generator function" {
    var scanner = Scanner.init(std.testing.allocator, "function* gen() { yield 1; yield 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: yield delegate" {
    var scanner = Scanner.init(std.testing.allocator, "function* gen() { yield* other(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async arrow function" {
    var scanner = Scanner.init(std.testing.allocator, "const f = async () => { await fetch(); };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    // async arrow는 현재 async가 expression statement로 파싱됨
    // 완전한 async arrow는 추후 구현 (BACKLOG #35)
}
