//! Declaration 파싱
//!
//! 함수 선언/표현식, 클래스 선언/표현식, 클래스 멤버 파싱 함수들.
//! oxc의 js/function.rs + js/class.rs에 대응.
//!
//! 참고:
//! - references/oxc/crates/oxc_parser/src/js/function.rs
//! - references/oxc/crates/oxc_parser/src/js/class.rs

const std = @import("std");
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;
const FunctionFlags = ast_mod.FunctionFlags;
const token_mod = @import("../lexer/token.zig");
const Kind = token_mod.Kind;
const Span = token_mod.Span;
const Parser = @import("parser.zig").Parser;
const ParseError2 = @import("parser.zig").ParseError2;

pub fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionDeclarationWithFlags(self, 0);
}

pub fn parseFunctionDeclarationWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip 'function'

    // generator: function* name()
    var flags = extra_flags;
    if (self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // ECMAScript 14.1: 함수 선언의 BindingIdentifier는 외부 context([?Yield, ?Await])에서 파싱.
    // enterFunctionContext 이전에 이름을 파싱해야 올바른 yield/await 검증이 된다.
    // 예: function* foo() { function yield() {} } — "yield"는 외부(generator) context에서 에러.
    const name = try self.parseBindingIdentifier();

    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    self.expect(.l_paren);
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(param);
        if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
            self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
        }
        if (!self.eat(.comma)) break;
    }
    self.expect(.r_paren);
    self.in_formal_parameters = false;

    // TS 리턴 타입 어노테이션
    const return_type = try self.tryParseReturnType();

    self.has_simple_params = self.checkSimpleParams(scratch_top);
    self.checkDuplicateParams(scratch_top);
    const body = try self.parseFunctionBody();

    // retroactive strict mode checks: "use strict" directive가 있으면
    // 함수 이름과 파라미터를 소급 검증 (ECMAScript 14.1.2)
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        self.checkStrictFunctionName(name);
        self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);
    _ = try self.ast.addExtra(@intFromEnum(return_type));

    return try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

/// async function / async arrow를 파싱한다.
/// async 뒤에 function이 오면 async function declaration,
/// 그 외는 expression statement로 처리.
pub fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
    const peek = self.peekNext();
    // async [no LineTerminator here] function → async function declaration
    if (peek.kind == .kw_function and !peek.has_newline_before) {
        self.advance(); // skip 'async'
        return parseFunctionDeclarationWithFlags(self, FunctionFlags.is_async);
    }
    // async 뒤에 줄바꿈이 있거나 function이 아니면 → expression statement
    return self.parseExpressionStatement();
}

/// export default function / function* — 이름이 선택적 (없으면 anonymous)
/// ECMAScript: HoistableDeclaration[+Default] → function (Params) { Body }
pub fn parseFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionDeclarationWithFlagsOptionalName(self, 0);
}

/// export default async function / async function* — 이름이 선택적
pub fn parseAsyncFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
    self.advance(); // skip 'async'
    return parseFunctionDeclarationWithFlagsOptionalName(self, FunctionFlags.is_async);
}

/// parseFunctionDeclarationWithFlags와 동일하지만 이름이 선택적.
/// export default에서만 사용.
pub fn parseFunctionDeclarationWithFlagsOptionalName(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip 'function'

    var flags = extra_flags;
    if (self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // 이름은 선택적: identifier가 있으면 외부 context에서 파싱
    const name = if (self.current() == .identifier or
        self.current() == .kw_yield or self.current() == .kw_await or
        self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved)
        try self.parseBindingIdentifier()
    else
        NodeIndex.none;

    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    self.expect(.l_paren);
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(param);
        if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
            self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
        }
        if (!self.eat(.comma)) break;
    }
    self.expect(.r_paren);
    self.in_formal_parameters = false;

    const return_type = try self.tryParseReturnType();

    self.has_simple_params = self.checkSimpleParams(scratch_top);
    self.checkDuplicateParams(scratch_top);
    const body = try self.parseFunctionBody();

    // retroactive strict mode checks
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        self.checkStrictFunctionName(name);
        self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);
    _ = try self.ast.addExtra(@intFromEnum(return_type));

    return try self.ast.addNode(.{
        .tag = .function_declaration,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
    return parseFunctionExpressionWithFlags(self, 0);
}

pub fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip 'function'

    // generator: function* () {}
    var flags: u32 = extra_flags;
    if (self.eat(.star)) {
        flags |= FunctionFlags.is_generator;
    }

    const is_async = (flags & FunctionFlags.is_async) != 0;
    const is_generator = (flags & FunctionFlags.is_generator) != 0;

    // 함수 컨텍스트 진입 — 이름/파라미터/본문 모두 이 컨텍스트에서 파싱
    const saved_ctx = self.enterFunctionContext(is_async, is_generator);

    var name = NodeIndex.none;
    if (self.current() == .identifier or self.current() == .kw_yield or self.current() == .kw_await) {
        name = try self.parseBindingIdentifier();
    }

    self.expect(.l_paren);
    self.in_formal_parameters = true;
    const scratch_top = self.saveScratch();
    while (self.current() != .r_paren and self.current() != .eof) {
        const param = try self.parseBindingIdentifier();
        try self.scratch.append(param);
        if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
            self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
        }
        if (!self.eat(.comma)) break;
    }
    self.expect(.r_paren);
    self.in_formal_parameters = false;

    // TS 리턴 타입 어노테이션
    _ = try self.tryParseReturnType();
    self.has_simple_params = self.checkSimpleParams(scratch_top);
    self.checkDuplicateParams(scratch_top);
    const body = try self.parseFunctionBodyExpr();

    // retroactive strict mode checks
    if (self.is_strict_mode and !saved_ctx.is_strict_mode) {
        self.checkStrictFunctionName(name);
        self.checkStrictParamNames(scratch_top);
    }

    self.restoreFunctionContext(saved_ctx);

    const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
    self.restoreScratch(scratch_top);
    const extra_start = try self.ast.addExtra(@intFromEnum(name));
    _ = try self.ast.addExtra(param_list.start);
    _ = try self.ast.addExtra(param_list.len);
    _ = try self.ast.addExtra(@intFromEnum(body));
    _ = try self.ast.addExtra(flags);

    return try self.ast.addNode(.{
        .tag = .function_expression,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
    return parseClassWithDecorators(self, .class_declaration, .{ .start = 0, .len = 0 });
}

pub fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
    return parseClassWithDecorators(self, .class_expression, .{ .start = 0, .len = 0 });
}

/// class 선언/표현식을 파싱한다.
/// extra = [name, super_class, body, type_params, implements_start, implements_len, deco_start, deco_len]
pub fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.advance(); // skip 'class'

    // ECMAScript 10.2.1: "All parts of a ClassDeclaration or a ClassExpression
    // are strict mode code." — 클래스 이름, extends, 본문 모두 strict mode.
    // 이를 통해 yield/let/static 등 strict mode reserved word가 클래스 이름으로
    // 사용되는 것을 금지하고, 본문 내 yield/await 사용도 올바르게 검증한다.
    const saved_strict_mode = self.is_strict_mode;
    self.is_strict_mode = true;

    // 클래스 이름 (선언은 필수, 표현식은 선택)
    // kw_yield/kw_await는 컨텍스트에 따라 식별자로 사용 가능
    var name = NodeIndex.none;
    if (self.current() == .identifier or
        (self.current() == .kw_yield and !self.ctx.in_generator) or
        (self.current() == .kw_await and !self.ctx.in_async and !self.is_module) or
        self.current() == .escaped_keyword or self.current() == .escaped_strict_reserved)
    {
        name = try self.parseBindingIdentifier();
    }

    // TS 제네릭 파라미터: class Foo<T> { }
    var type_params = NodeIndex.none;
    if (self.current() == .l_angle) {
        type_params = try self.parseTsTypeParameterDeclaration();
    }

    // extends 절 (선택)
    // ECMAScript: ClassHeritage : extends LeftHandSideExpression
    // LeftHandSideExpression은 CallExpression | NewExpression | OptionalExpression이지
    // ArrowFunctionExpression이나 AssignmentExpression은 아니다.
    // parseCallExpression을 사용하여 arrow function이 heritage에서 파싱되지 않도록 한다.
    // 예: `class extends () => {} {}` → SyntaxError (arrow의 {}가 class body와 충돌)
    var super_class = NodeIndex.none;
    if (self.eat(.kw_extends)) {
        super_class = try self.parseCallExpression();
    }

    // TS implements 절 (선택): class Foo implements Bar, Baz
    if (self.eat(.kw_implements)) {
        _ = try self.parseType();
        while (self.eat(.comma)) {
            _ = try self.parseType();
        }
    }

    // 클래스 본문 — extends 있으면 has_super_class 설정 (super() 허용 판단)
    // 중첩 class에서 외부 has_super_class를 상속하지 않도록 명시적 설정
    const saved_has_super_class = self.has_super_class;
    self.has_super_class = !super_class.isNone();
    const body = try parseClassBody(self);
    self.has_super_class = saved_has_super_class;

    // strict mode 복원 — 클래스 외부의 strict 상태로 되돌림
    self.is_strict_mode = saved_strict_mode;

    const none = @intFromEnum(NodeIndex.none);
    const extra_start = try self.ast.addExtras(&.{
        @intFromEnum(name),
        @intFromEnum(super_class),
        @intFromEnum(body),
        @intFromEnum(type_params),
        0,                0, // implements (스트리핑 대상이므로 빈 리스트)
        decorators.start, decorators.len,
    });
    _ = none;

    return try self.ast.addNode(.{
        .tag = tag,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = extra_start },
    });
}

pub fn parseClassBody(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;
    self.expect(.l_curly);

    // class body 안에서는 in_class=true (super 허용 등)
    const saved_in_class = self.in_class;
    self.in_class = true;

    const scratch_top = self.saveScratch();
    while (self.current() != .r_curly and self.current() != .eof) {
        // 세미콜론 스킵 (클래스 본문에서 허용)
        if (self.current() == .semicolon) {
            self.advance();
            continue;
        }
        const member = try parseClassMember(self);
        if (!member.isNone()) try self.scratch.append(member);
    }

    self.in_class = saved_in_class;

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

pub fn parseClassMember(self: *Parser) ParseError2!NodeIndex {
    const start = self.currentSpan().start;

    // 데코레이터 (class member 앞) — scratch에 수집 후 멤버 노드의 extra_data에 연결
    const deco_scratch_top = self.saveScratch();
    while (self.current() == .at) {
        const dec = try self.parseDecorator();
        try self.scratch.append(dec);
    }
    const decorators = try self.ast.addNodeList(self.scratch.items[deco_scratch_top..]);
    self.restoreScratch(deco_scratch_top);

    // TS 접근 제어자 (public/private/protected) + readonly + abstract + override
    while (self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected or self.current() == .kw_readonly or
        self.current() == .kw_abstract or self.current() == .kw_override or
        self.current() == .kw_declare)
    {
        self.advance(); // skip modifier (스트리핑 대상이므로 AST에 저장 불필요)
    }

    // static 키워드 (선택)
    // static은 멤버 이름으로도 사용 가능: class C { static() {} }
    // static 뒤에 {, (, = 가 오면 이름으로 취급
    var flags: u16 = 0;
    if (self.current() == .kw_static) {
        const next = self.peekNextKind();
        if (next == .l_curly) {
            // static { } — static block
            // static initializer는 자체 arguments 바인딩이 없음.
            // new.target은 허용 (undefined로 평가, ECMAScript 15.7.15)
            self.advance(); // skip 'static'
            const saved_in_static = self.in_static_initializer;
            const saved_new_target = self.allow_new_target;
            const saved_in_function = self.ctx.in_function;
            const saved_in_loop = self.in_loop;
            const saved_in_switch = self.in_switch;
            const saved_in_generator = self.ctx.in_generator;
            const saved_in_async = self.ctx.in_async;
            const saved_super_property = self.allow_super_property;
            self.in_static_initializer = true;
            self.allow_new_target = true;
            self.allow_super_property = true; // static block에서 super.prop 허용 (ECMAScript 15.7.14)
            // static block은 독립 실행 컨텍스트: return/break/continue/yield 금지
            // +Await: await은 binding identifier로 사용 불가 (ECMAScript 15.7.12)
            self.ctx.in_function = false;
            self.in_loop = false;
            self.in_switch = false;
            self.ctx.in_generator = false;
            self.ctx.in_async = true;
            const body = try self.parseBlockStatement();
            self.in_static_initializer = saved_in_static;
            self.allow_new_target = saved_new_target;
            self.ctx.in_function = saved_in_function;
            self.in_loop = saved_in_loop;
            self.in_switch = saved_in_switch;
            self.ctx.in_generator = saved_in_generator;
            self.ctx.in_async = saved_in_async;
            self.allow_super_property = saved_super_property;
            return try self.ast.addNode(.{
                .tag = .static_block,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = body, .flags = 0 } },
            });
        }
        // static 뒤에 (나 = 가 오면 static은 메서드/프로퍼티 이름
        if (next != .l_paren and next != .eq and next != .semicolon) {
            flags |= 0x01; // static modifier
            self.advance();
        }
    }

    // static 뒤의 TS modifier도 소비 (static readonly x 등)
    while (self.current() == .kw_readonly or self.current() == .kw_abstract or
        self.current() == .kw_override or self.current() == .kw_declare or
        self.current() == .kw_public or self.current() == .kw_private or
        self.current() == .kw_protected)
    {
        self.advance();
    }

    // accessor (선택): TC39 Decorators proposal — `accessor x = 1`
    // accessor는 modifier이므로 get/set보다 먼저 파싱.
    // `accessor get(){}` → "get"이라는 이름의 accessor field (get은 메서드 이름).
    // `accessor()`, `accessor;`, `accessor =` 는 "accessor"라는 이름의 일반 멤버.
    var is_accessor = false;
    if (self.current() == .kw_accessor) {
        const next = self.peekNextKind();
        if (next != .l_paren and next != .eq and next != .semicolon and
            next != .r_curly and next != .eof)
        {
            is_accessor = true;
            self.advance(); // skip 'accessor'
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

    // async (선택): async [no LineTerminator here] MethodName
    // 스펙: async와 다음 토큰(*/PropertyName) 사이에 줄바꿈이 없어야 함
    if (self.current() == .kw_async and self.peekNextKind() != .l_paren and
        !self.peekNext().has_newline_before)
    {
        flags |= 0x08; // async flag
        self.advance();
    }

    // generator (선택): *method() {}
    if (self.eat(.star)) {
        flags |= 0x10; // generator flag
    }

    // 키
    const key = try self.parsePropertyKey();

    // 제네릭 파라미터: method<T>()
    if (self.current() == .l_angle) {
        _ = try self.parseTsTypeParameterDeclaration();
    }

    // 메서드 (파라미터 리스트가 있으면)
    if (self.current() == .l_paren) {
        // 메서드 파라미터는 자체 arguments 바인딩을 가지므로
        // static initializer/class field의 arguments 제한이 적용되지 않는다.
        const saved_in_static_init = self.in_static_initializer;
        const saved_in_class_field_for_params = self.in_class_field;
        const saved_in_async_for_params = self.ctx.in_async;
        const saved_in_generator_for_params = self.ctx.in_generator;
        const saved_super_prop_for_params = self.allow_super_property;
        self.in_static_initializer = false;
        self.in_class_field = false;
        // 메서드의 파라미터에서 async/generator 컨텍스트 설정
        // 非async/非generator 메서드에서는 await/yield를 식별자로 사용 가능
        self.ctx.in_async = (flags & 0x08) != 0;
        self.ctx.in_generator = (flags & 0x10) != 0;
        // class 메서드의 파라미터에서 super.prop 허용 (ECMAScript 15.7.5)
        self.allow_super_property = true;
        self.expect(.l_paren);
        self.in_formal_parameters = true;
        const param_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        self.in_formal_parameters = false;

        // TS 리턴 타입 어노테이션: (): Type
        _ = try self.tryParseReturnType();

        // static method 'prototype' 금지 (ECMAScript 15.7.1)
        // private method '#constructor' 금지
        if (!key.isNone()) {
            const mk = self.ast.getNode(key);
            const method_name = if (mk.tag == .identifier_reference)
                self.ast.source[mk.span.start..mk.span.end]
            else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
            else
                @as([]const u8, "");
            if ((flags & 0x01) != 0 and std.mem.eql(u8, method_name, "prototype")) {
                self.addError(mk.span, "static class method cannot be named 'prototype'");
            }
            // constructor는 일반 method만 가능 — getter/setter/generator/async 금지
            if ((flags & 0x01) == 0 and std.mem.eql(u8, method_name, "constructor")) {
                // flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
                if ((flags & 0x1E) != 0) {
                    self.addError(mk.span, "class constructor cannot be a getter, setter, generator, or async");
                }
            }
            // private name '#constructor' 금지
            if (mk.tag == .private_identifier) {
                const pn = self.ast.source[mk.span.start..mk.span.end];
                if (std.mem.eql(u8, pn, "#constructor")) {
                    self.addError(mk.span, "class member cannot be named '#constructor'");
                }
            }
        }

        // 바디: abstract 메서드는 바디 없음 (세미콜론으로 끝남)
        // 메서드도 함수이므로 컨텍스트 설정
        var body = NodeIndex.none;
        if (self.current() == .l_curly) {
            // 메서드의 async/generator 플래그는 함수와 비트 위치가 다름 (0x08/0x10)
            const saved_ctx = self.enterFunctionContext((flags & 0x08) != 0, (flags & 0x10) != 0);
            // class 메서드는 super.prop 허용 (ECMAScript 12.3.7)
            self.allow_super_property = true;
            // constructor에서는 super() 호출도 허용
            if (!key.isNone() and (flags & 0x01) == 0) { // non-static
                const mk = self.ast.getNode(key);
                const kt = if (mk.tag == .identifier_reference)
                    self.ast.source[mk.span.start..mk.span.end]
                else if (mk.tag == .string_literal and mk.span.end > mk.span.start + 2)
                    self.ast.source[mk.span.start + 1 .. mk.span.end - 1]
                else
                    @as([]const u8, "");
                if (std.mem.eql(u8, kt, "constructor")) {
                    // extends가 있는 class의 constructor에서만 super() 허용
                    if (self.has_super_class) {
                        self.allow_super_call = true;
                    }
                }
            }
            self.has_simple_params = self.checkSimpleParams(param_top);
            self.checkDuplicateParams(param_top);
            body = try self.parseFunctionBodyExpr();
            self.restoreFunctionContext(saved_ctx);
        } else {
            _ = self.eat(.semicolon);
        }
        // 파라미터 전에 변경한 플래그 복원 (if/else 양쪽 공통)
        // restoreFunctionContext는 enterFunctionContext 시점의 (이미 false인) 값을
        // 복원하므로, 여기서 원래 값으로 다시 복원해야 한다.
        self.in_static_initializer = saved_in_static_init;
        self.in_class_field = saved_in_class_field_for_params;
        self.ctx.in_async = saved_in_async_for_params;
        self.ctx.in_generator = saved_in_generator_for_params;
        self.allow_super_property = saved_super_prop_for_params;
        const param_list = try self.ast.addNodeList(self.scratch.items[param_top..]);
        self.restoreScratch(param_top);

        // method_definition: extra = [key, params_start, params_len, body, flags, deco_start, deco_len]
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(key),
            param_list.start,
            param_list.len,
            @intFromEnum(body),
            flags,
            decorators.start,
            decorators.len,
        });

        return try self.ast.addNode(.{
            .tag = .method_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // class field 이름 검증 (ECMAScript 15.7.1)
    if (!key.isNone()) {
        const key_node = self.ast.getNode(key);
        // identifier 또는 string literal 키에서 이름 추출
        const key_text = if (key_node.tag == .identifier_reference)
            self.ast.source[key_node.span.start..key_node.span.end]
        else if (key_node.tag == .string_literal and key_node.span.end > key_node.span.start + 2)
            self.ast.source[key_node.span.start + 1 .. key_node.span.end - 1] // 따옴표 제거
        else
            @as([]const u8, "");

        if (key_text.len > 0) {
            // class field 이름 'constructor' 금지 — static/non-static 모두 (ECMAScript 15.7.1)
            if (std.mem.eql(u8, key_text, "constructor")) {
                self.addError(key_node.span, "class field cannot be named 'constructor'");
            }
            if ((flags & 0x01) != 0 and std.mem.eql(u8, key_text, "prototype")) {
                self.addError(key_node.span, "static class field cannot be named 'prototype'");
            }
        }
        // private field '#constructor' 금지
        if (key_node.tag == .private_identifier) {
            const pn = self.ast.source[key_node.span.start..key_node.span.end];
            if (std.mem.eql(u8, pn, "#constructor")) {
                self.addError(key_node.span, "class member cannot be named '#constructor'");
            }
        }
    }

    // TS 타입 어노테이션: value: Type
    _ = try self.tryParseTypeAnnotation();

    // 프로퍼티 (= 이니셜라이저) — class field에서 arguments 사용 금지
    var init_val = NodeIndex.none;
    if (self.eat(.eq)) {
        const saved_in_class_field = self.in_class_field;
        const saved_new_target = self.allow_new_target;
        const saved_super_property = self.allow_super_property;
        self.in_class_field = true;
        self.allow_new_target = true; // class field에서 new.target 허용 (ECMAScript 15.7.15)
        self.allow_super_property = true; // class field에서 super.prop 허용 (ECMAScript 15.7.5)
        init_val = try self.parseAssignmentExpression();
        self.in_class_field = saved_in_class_field;
        self.allow_new_target = saved_new_target;
        self.allow_super_property = saved_super_property;
    }
    // class field 끝에서 ASI 규칙 적용: 같은 줄에 다른 멤버가 오면 에러
    self.expectSemicolon();

    // property_definition / accessor_property:
    // extra = [key, init_val, flags, deco_start, deco_len]
    const prop_extra_start = try self.ast.addExtras(&.{
        @intFromEnum(key),
        @intFromEnum(init_val),
        flags,
        decorators.start,
        decorators.len,
    });
    return try self.ast.addNode(.{
        .tag = if (is_accessor) .accessor_property else .property_definition,
        .span = .{ .start = start, .end = self.currentSpan().start },
        .data = .{ .extra = prop_extra_start },
    });
}
