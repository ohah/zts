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
const Token = token_mod.Token;
const ast_mod = @import("ast.zig");
const Ast = ast_mod.Ast;
const Node = ast_mod.Node;
const Tag = Node.Tag;
const NodeIndex = ast_mod.NodeIndex;
const NodeList = ast_mod.NodeList;

/// 파서 에러 하나.
pub const ParseError = struct {
    span: Span,
    message: []const u8,
};

/// 재귀 함수용 명시적 에러 타입.
/// Zig는 재귀 함수에서 `!T` (inferred error set)를 사용할 수 없다.
/// 파서의 모든 에러는 메모리 할당 실패뿐이므로 Allocator.Error로 충분하다.
const ParseError2 = std.mem.Allocator.Error;

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

    // ================================================================
    // 컨텍스트 플래그 (D051: 파서에서 구문 컨텍스트 추적)
    // ================================================================
    //
    // Context는 packed struct(u32)로 구현된 bitflags다.
    // 함수 진입/퇴장 시 save/restore 대상이 되는 모든 플래그를 하나로 묶어,
    // 저장/복원을 단순 대입으로 처리한다 (oxc/Babel/Bun 공통 패턴).
    //
    // is_module은 파싱 시작 시 한 번 결정되고 변하지 않는 불변 설정이므로
    // Context에 포함하지 않고 별도 필드로 관리한다 (oxc/Babel/Hermes 방식).

    /// 파싱 컨텍스트 bitflags. 함수/블록 경계에서 save/restore 대상.
    ctx: Context = Context.default,

    /// module 모드인지 (import/export 허용, 항상 strict).
    /// 파싱 시작 시 한 번 결정되는 불변 설정이므로 Context에 포함하지 않음.
    is_module: bool = false,

    // ================================================================
    // Context packed struct 정의
    // ================================================================

    /// 파서의 구문 컨텍스트를 추적하는 bitflags.
    ///
    /// packed struct(u32)를 사용하면:
    /// - 22개 bool 필드가 4바이트 하나에 들어감 (개별 bool이면 22바이트)
    /// - save/restore가 u32 대입 한 번으로 끝남 (구조체 필드 7개 복사 → 1개)
    /// - 비트 연산으로 여러 플래그를 한꺼번에 조작 가능
    ///
    /// 기본값 주의: has_simple_params, allow_in, is_top_level은 기본값이 true.
    pub const Context = packed struct(u32) {
        // --- 기본 ECMAScript 컨텍스트 (비트 0~7) ---

        /// strict mode 여부 (D054: "use strict" directive 또는 module mode)
        is_strict_mode: bool = false,
        /// 함수 본문 안에 있는지 (return 유효성 검증용)
        in_function: bool = false,
        /// async 함수 안에 있는지 (await 키워드 유효성 검증용)
        in_async: bool = false,
        /// generator 함수 안에 있는지 (yield 키워드 유효성 검증용)
        in_generator: bool = false,
        /// 루프 안에 있는지 (continue 유효성 검증용)
        in_loop: bool = false,
        /// switch 안에 있는지 (break 유효성 검증용 — break는 loop OR switch에서 허용)
        in_switch: bool = false,
        /// 현재 파싱 중인 함수의 파라미터가 simple인지 (non-simple이면 "use strict" 금지)
        has_simple_params: bool = true,
        /// `in` 연산자 허용 여부 (for-in/for-of 초기화절에서는 false로 설정하여
        /// `in`을 관계 연산자가 아닌 for-in 키워드로 파싱)
        allow_in: bool = true,

        // --- 추가 ECMAScript 컨텍스트 (비트 8~11) ---

        /// 최상위 레벨인지 (top-level await 감지용)
        is_top_level: bool = true,
        /// decorator 파싱 중인지
        in_decorator: bool = false,
        /// for 초기화절 안인지 (for-in/for-of 구분)
        for_loop_init: bool = false,
        /// 함수 파라미터 안인지
        in_parameters: bool = false,

        // --- class 관련 컨텍스트 (비트 12~17) ---

        /// class 본문 안인지
        in_class: bool = false,
        /// class field 초기값 안인지
        in_class_field: bool = false,
        /// static block 안인지
        in_static_block: bool = false,
        /// extends 있는 class인지 (super() 허용 판단)
        has_super_class: bool = false,
        /// super() 호출 허용 여부 (constructor + extends)
        allow_super_call: bool = false,
        /// super.x / super[x] 허용 여부
        allow_super_property: bool = false,

        // --- TypeScript 컨텍스트 (비트 18~20) ---

        /// TS 타입 어노테이션 안인지 (렉서 동작 변경: `<`/`>`를 타입 구분자로)
        in_type: bool = false,
        /// TS declare 블록 또는 .d.ts 파일 안인지
        in_ambient: bool = false,
        /// TS 조건부 타입 금지 (infer 절에서 extends를 제약으로 파싱)
        disallow_conditional_types: bool = false,

        // --- 기타 (비트 21~22) ---

        /// new.target 허용 여부
        allow_new_target: bool = false,
        /// constructor 안인지
        is_constructor: bool = false,

        // 남은 비트는 padding (향후 확장용)
        _padding: u9 = 0,

        /// 기본값: has_simple_params=true, allow_in=true, is_top_level=true, 나머지 false.
        pub const default: Context = .{};

        /// 함수 진입 시 컨텍스트를 설정한다.
        /// in_function=true, in_loop/in_switch=false (함수 안의 break/continue는 함수 밖 loop에 속하지 않음),
        /// is_top_level=false, async/generator는 인자로 설정.
        /// 나머지 플래그(is_strict_mode 등)는 유지한다.
        pub fn enterFunction(self: Context, is_async: bool, is_generator: bool) Context {
            var new = self;
            new.in_function = true;
            new.in_async = is_async;
            new.in_generator = is_generator;
            new.in_loop = false;
            new.in_switch = false;
            new.is_top_level = false;
            // 일반 function은 새로운 super 바인딩 → 메서드가 아니면 super 불가
            // (arrow function은 enterFunction을 사용하지 않고 별도로 처리)
            new.allow_super_call = false;
            new.allow_super_property = false;
            new.in_class_field = false; // 일반 function은 자체 arguments 있음
            return new;
        }
    };

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

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용하면 에러.
    fn checkStrictBinding(self: *Parser, span: Span) void {
        if (!self.ctx.is_strict_mode) return;
        const text = self.ast.source[span.start..span.end];
        if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
            self.addError(span, "assignment to 'eval' or 'arguments' is not allowed in strict mode");
        }
    }

    /// strict mode에서 eval/arguments에 할당하면 에러 (ECMAScript 13.15.1).
    fn checkStrictAssignmentTarget(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .identifier_reference) {
            self.checkStrictBinding(node.span);
        } else if (node.tag == .parenthesized_expression) {
            self.checkStrictAssignmentTarget(node.data.unary.operand);
        }
    }

    /// assignment target이 유효한지 검증한다.
    /// valid: identifier, member expression, parenthesized(valid target)
    /// invalid: literal, binary, call, arrow, etc.
    fn isValidAssignmentTarget(self: *const Parser, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .identifier_reference, .private_identifier => true,
            .static_member_expression, .computed_member_expression => {
                // optional chaining (a?.b, a?.[b])은 assignment target이 아님
                return node.data.binary.flags == 0; // 0 = normal, 1 = optional
            },
            .private_field_expression => true,
            // destructuring assignment: [a, b] = [1, 2], { a } = obj
            .array_expression, .object_expression => true,
            .parenthesized_expression => {
                // (x) = 1 → x가 simple target이면 OK
                // ({x}) = 1, ([x]) = 1 → parenthesized destructuring 금지
                const inner = node.data.unary.operand;
                if (inner.isNone()) return false;
                const inner_tag = self.ast.getNode(inner).tag;
                if (inner_tag == .array_expression or inner_tag == .object_expression) return false;
                return self.isValidAssignmentTarget(inner);
            },
            // super.x, super[x]는 static/computed_member_expression으로 처리됨
            // bare super는 assignment target이 아님
            else => false,
        };
    }

    const rest_init_error = "rest element may not have a default initializer";

    /// binding pattern에서 rest element가 assignment_pattern(= initializer)이면 에러.
    /// parseArrayPattern, parseObjectPattern, parseBindingPattern의 rest 처리에서 공통 사용.
    fn checkBindingRestInit(self: *Parser, rest_arg: NodeIndex) void {
        if (rest_arg.isNone()) return;
        const rest_node = self.ast.getNode(rest_arg);
        if (rest_node.tag == .assignment_pattern) {
            self.addError(rest_node.span, rest_init_error);
        }
    }

    /// spread element의 operand가 assignment_expression이면 에러를 내고,
    /// operand가 nested pattern이면 재귀 검증.
    fn checkSpreadRestInit(self: *Parser, spread_operand: NodeIndex) void {
        const operand = self.ast.getNode(spread_operand);
        if (operand.tag == .assignment_expression) {
            self.addError(operand.span, rest_init_error);
        }
        self.checkRestInitInAssignmentPattern(spread_operand);
    }

    /// assignment destructuring에서 rest/spread element에 initializer가 있으면 에러.
    /// ECMAScript: AssignmentRestElement에는 Initializer가 올 수 없다.
    /// `[...x = 1] = arr` → SyntaxError
    fn checkRestInitInAssignmentPattern(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .array_expression) {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                if (elem_idx.isNone()) continue;
                const elem = self.ast.getNode(elem_idx);
                if (elem.tag == .spread_element) {
                    self.checkSpreadRestInit(elem.data.unary.operand);
                }
                // nested destructuring: [x = [...y = 1]] → left가 pattern이면 재귀 검증
                if (elem.tag == .assignment_expression) {
                    self.checkRestInitInAssignmentPattern(elem.data.binary.left);
                }
            }
        } else if (node.tag == .object_expression) {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                if (elem_idx.isNone()) continue;
                const elem = self.ast.getNode(elem_idx);
                if (elem.tag == .spread_element) {
                    self.checkSpreadRestInit(elem.data.unary.operand);
                }
                // nested destructuring: {a: [...x = 1]} → value가 pattern이면 재귀 검증
                if (elem.tag == .object_property) {
                    self.checkRestInitInAssignmentPattern(elem.data.binary.right);
                }
            }
        }
    }

    /// arrow function 파라미터에서 rest-init 검증.
    /// `([...x = 1]) => {}` — 파라미터가 expression으로 파싱된 경우,
    /// parenthesized/sequence를 풀어 내부 패턴을 검증한다.
    fn checkRestInitInArrowParams(self: *Parser, idx: NodeIndex) void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .parenthesized_expression) {
            self.checkRestInitInArrowParams(node.data.unary.operand);
        } else if (node.tag == .sequence_expression) {
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                self.checkRestInitInAssignmentPattern(elem_idx);
            }
        } else {
            self.checkRestInitInAssignmentPattern(idx);
        }
    }

    /// 키워드를 바인딩 위치에서 사용할 때의 검증.
    /// ECMAScript 12.1.1: reserved keyword, strict mode reserved, contextual keywords.
    fn checkKeywordBinding(self: *Parser) void {
        // await는 조건부 예약어 — async/module에서만 금지, script에서는 식별자로 사용 가능
        // yield도 조건부 — generator/strict에서만 금지
        // 둘 다 checkYieldAwaitUse에서 처리
        if (self.current() == .kw_await or self.current() == .kw_yield) {
            self.checkYieldAwaitUse(self.currentSpan(), "identifier");
        } else if (self.current().isReservedKeyword() or self.current().isLiteralKeyword()) {
            self.addError(self.currentSpan(), "reserved word cannot be used as identifier");
        } else if (self.ctx.is_strict_mode and self.current().isStrictModeReserved()) {
            self.addError(self.currentSpan(), "reserved word in strict mode cannot be used as identifier");
        }
    }

    /// yield/await를 식별자/레이블/바인딩으로 사용할 때의 검증.
    /// ECMAScript 13.1.1: yield는 [Yield] 또는 strict mode에서, await는 [Await] 또는 module에서 금지.
    /// context_noun: "identifier", "label" 등 — 에러 메시지에 사용 (comptime 문자열 연결).
    fn checkYieldAwaitUse(self: *Parser, span: Span, comptime context_noun: []const u8) void {
        if (self.current() == .kw_yield) {
            if (self.ctx.in_generator) {
                self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in generator");
            } else if (self.ctx.is_strict_mode) {
                self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in strict mode");
            }
        } else if (self.current() == .kw_await) {
            if (self.ctx.in_async) {
                self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in async function");
            } else if (self.is_module) {
                self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in module code");
            }
        }
    }

    // ================================================================
    // 컨텍스트 저장/복원 (D051: 함수 경계에서 컨텍스트 리셋)
    // ================================================================
    //
    // Context가 packed struct(u32)이므로 저장/복원이 단순 대입이다.
    // 함수 진입: saved = self.ctx; self.ctx = self.ctx.enterFunction(...)
    // 함수 퇴장: self.ctx = saved;
    //
    // enterFunctionContext()는 이 패턴을 함수로 감싸 실수를 방지한다.

    /// 함수 컨텍스트를 설정한다.
    /// 현재 ctx를 반환(저장)하고, ctx를 함수 진입 상태로 변경한다.
    /// 함수/메서드/arrow 진입 시 호출하고, 본문 파싱 후 restoreContext()로 복원.
    fn enterFunctionContext(self: *Parser, is_async: bool, is_generator: bool) Context {
        const saved = self.ctx;
        self.ctx = self.ctx.enterFunction(is_async, is_generator);
        return saved;
    }

    /// 저장된 컨텍스트를 복원한다.
    fn restoreContext(self: *Parser, saved: Context) void {
        self.ctx = saved;
    }

    /// `in` 연산자 허용/금지 컨텍스트에 진입한다.
    /// ECMAScript 문법의 [+In]/[~In] 파라미터 전환에 사용.
    /// 반환값을 restoreContext()에 전달하여 복원.
    fn enterAllowInContext(self: *Parser, allow: bool) Context {
        const saved = self.ctx;
        self.ctx.allow_in = allow;
        return saved;
    }

    /// 현재 토큰이 "use strict" directive인지 확인한다.
    /// directive prologue에서 호출 — tokenText()는 따옴표를 포함하므로 내부를 비교.
    fn isUseStrictDirective(self: *const Parser) bool {
        if (self.current() != .string_literal) return false;
        const text = self.tokenText();
        // "use strict" 또는 'use strict' — 따옴표 포함 길이 = "use strict".len + 2 = 12
        if (text.len < "\"use strict\"".len) return false;
        const inner = text[1 .. text.len - 1];
        return std.mem.eql(u8, inner, "use strict");
    }

    /// 루프 본문을 파싱한다. 전체 ctx를 save/restore하여 일관성 유지.
    fn parseLoopBody(self: *Parser) ParseError2!NodeIndex {
        const saved = self.ctx;
        self.ctx.in_loop = true;
        const body = try self.parseStatementChecked(true);
        self.ctx = saved;
        return body;
    }

    /// 파라미터 리스트가 simple인지 검사한다.
    /// simple = 모든 파라미터가 binding_identifier (destructuring, default, rest 없음)
    fn checkSimpleParams(self: *const Parser, scratch_top: usize) bool {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            if (param_idx.isNone()) continue;
            const node = self.ast.getNode(param_idx);
            switch (node.tag) {
                .binding_identifier => {}, // simple
                else => return false, // destructuring, default, rest, formal_parameter 등
            }
        }
        return true;
    }

    /// strict mode 또는 non-simple params에서 중복 파라미터를 검사한다.
    fn checkDuplicateParams(self: *Parser, scratch_top: usize) void {
        if (!self.ctx.is_strict_mode and self.ctx.has_simple_params) return;
        const params = self.scratch.items[scratch_top..];
        // O(N²)이지만 파라미터 수가 적으므로 (보통 <10) 충분
        for (params, 0..) |param_idx, i| {
            if (param_idx.isNone()) continue;
            const node = self.ast.getNode(param_idx);
            if (node.tag != .binding_identifier) continue;
            const name = self.ast.source[node.span.start..node.span.end];
            for (params[0..i]) |prev_idx| {
                if (prev_idx.isNone()) continue;
                const prev = self.ast.getNode(prev_idx);
                if (prev.tag != .binding_identifier) continue;
                const prev_name = self.ast.source[prev.span.start..prev.span.end];
                if (std.mem.eql(u8, name, prev_name)) {
                    self.addError(node.span, "duplicate parameter name");
                    break;
                }
            }
        }
    }

    /// 함수 본문을 파싱한다.
    /// block statement와 동일하지만, "use strict" directive를 감지하여 strict mode를 설정한다.
    fn parseFunctionBody(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        // directive prologue: 본문 시작의 문자열 리터럴 expression statement 중 "use strict" 감지
        var in_directive_prologue = true;

        while (self.current() != .r_curly and self.current() != .eof) {
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    // non-simple parameters + "use strict" → 에러
                    // ECMAScript 14.1.2: function with non-simple parameter list
                    // shall not contain a Use Strict Directive
                    if (!self.ctx.has_simple_params) {
                        self.addError(self.currentSpan(), "\"use strict\" not allowed in function with non-simple parameters");
                    }
                    self.ctx.is_strict_mode = true;
                } else if (self.current() != .string_literal) {
                    in_directive_prologue = false;
                }
            }

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

    // ================================================================
    // 프로그램 파싱 (최상위)
    // ================================================================

    /// 소스 전체를 파싱하여 AST를 반환한다.
    pub fn parse(self: *Parser) !NodeIndex {
        self.advance(); // 첫 토큰 로드

        // module 모드면 항상 strict (D054)
        if (self.is_module) {
            self.ctx.is_strict_mode = true;
        }

        // hashbang (#! ...) 건너뛰기
        if (self.current() == .hashbang_comment) {
            self.advance();
        }

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        // directive prologue 감지: 프로그램 시작 부분의 "use strict"
        var in_directive_prologue = true;

        while (self.current() != .eof) {
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    self.ctx.is_strict_mode = true;
                } else if (self.current() != .string_literal) {
                    // directive prologue는 문자열 expression statement가 연속되는 동안 유효
                    in_directive_prologue = false;
                }
            }

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

    /// statement position에서 lexical/function declaration 금지를 체크한 뒤 parseStatement 호출.
    /// is_loop_body: true면 for/while/do-while body (function도 항상 금지)
    ///               false면 if/else/with/labeled body (function은 Annex B로 non-strict 허용)
    fn parseStatementChecked(self: *Parser, comptime is_loop_body: bool) ParseError2!NodeIndex {
        switch (self.current()) {
            .kw_const => {
                self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
            },
            .kw_let => {
                if (self.ctx.is_strict_mode) {
                    self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
                } else {
                    const next = self.peekNext();
                    // let 뒤에 줄바꿈 없이 identifier/[/{가 오면 lexical declaration
                    if (!next.has_newline_before and
                        (next.kind == .identifier or next.kind == .l_bracket or next.kind == .l_curly))
                    {
                        self.addError(self.currentSpan(), "lexical declaration is not allowed in statement position");
                    }
                }
            },
            .kw_class => {
                // class declaration은 statement position에서 항상 금지 (Annex B에 class 예외 없음)
                self.addError(self.currentSpan(), "class declaration is not allowed in statement position");
            },
            .kw_function => {
                if (self.peekNextKind() == .star) {
                    // generator는 항상 금지
                    self.addError(self.currentSpan(), "generator declaration is not allowed in statement position");
                } else if (is_loop_body) {
                    // loop body에서 function은 항상 금지 (ECMAScript 13.7.4, Annex B 미적용)
                    self.addError(self.currentSpan(), "function declaration is not allowed in statement position");
                } else if (self.ctx.is_strict_mode) {
                    // if/else/with/labeled body에서는 strict mode에서만 금지
                    self.addError(self.currentSpan(), "function declaration is not allowed in statement position in strict mode");
                }
            },
            .kw_async => {
                const peek = self.peekNext();
                if (peek.kind == .kw_function and !peek.has_newline_before) {
                    self.addError(self.currentSpan(), "async function declaration is not allowed in statement position");
                }
            },
            .kw_export => {
                self.addError(self.currentSpan(), "'export' is not allowed in statement position");
            },
            .kw_import => {
                // import()와 import.meta는 expression이므로 제외
                const peek = self.peekNextKind();
                if (peek != .l_paren and peek != .dot) {
                    self.addError(self.currentSpan(), "'import' is not allowed in statement position");
                }
            },
            else => {},
        }
        return self.parseStatement();
    }

    fn parseStatement(self: *Parser) ParseError2!NodeIndex {
        return switch (self.current()) {
            .l_curly => self.parseBlockStatement(),
            .semicolon => self.parseEmptyStatement(),
            .kw_var, .kw_let => self.parseVariableDeclaration(),
            .kw_const => if (self.peekNextKind() == .kw_enum)
                self.parseConstEnum()
            else
                self.parseVariableDeclaration(),
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
            .kw_import => blk: {
                const next = self.peekNextKind();
                break :blk if (next == .l_paren or next == .dot)
                    self.parseExpressionStatement()
                else
                    self.parseImportDeclaration();
            },
            .kw_export => self.parseExportDeclaration(),
            // Decorator: @expr class Foo {}
            .at => self.parseDecoratedStatement(),
            // TypeScript declarations
            .kw_type => self.parseTsTypeAliasDeclaration(),
            .kw_interface => self.parseTsInterfaceDeclaration(),
            .kw_enum => self.parseTsEnumDeclaration(),
            .kw_namespace, .kw_module => self.parseTsModuleDeclaration(),
            .kw_declare => self.parseTsDeclareStatement(),
            .kw_abstract => self.parseTsAbstractClass(),
            .kw_with => self.parseWithStatement(),
            else => self.parseExpressionOrLabeledStatement(),
        };
    }

    fn parseBlockStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        // 블록 안에서는 top-level이 아님 (import/export 금지)
        const block_saved = self.ctx;
        self.ctx.is_top_level = false;

        var stmts = std.ArrayList(NodeIndex).init(self.allocator);
        defer stmts.deinit();

        while (self.current() != .r_curly and self.current() != .eof) {
            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try stmts.append(stmt);
        }

        self.ctx = block_saved;

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    fn parseEmptyStatement(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        self.advance(); // skip ;
        return try self.ast.addNode(.{
            .tag = .empty_statement,
            .span = span,
            .data = .{ .none = 0 },
        });
    }

    fn parseExpressionStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const expr = try self.parseExpression();
        const end = self.currentSpan().end;
        _ = self.eat(.semicolon); // 세미콜론은 선택적 (ASI)
        return try self.ast.addNode(.{
            .tag = .expression_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
        });
    }

    /// expression statement 또는 labeled statement를 파싱한다.
    /// `identifier:` 패턴이면 labeled statement, 아니면 expression statement.
    fn parseExpressionOrLabeledStatement(self: *Parser) ParseError2!NodeIndex {
        // identifier/keyword: statement — labeled statement 판별
        if (self.current() == .identifier or self.current() == .escaped_keyword or
            (self.current().isKeyword() and !self.current().isReservedKeyword() and !self.current().isLiteralKeyword()))
        {
            const peek = self.peekNext();
            if (peek.kind == .colon) {
                // yield/await를 label로 사용하면 generator/async에서 에러
                self.checkYieldAwaitUse(self.currentSpan(), "label");
                if (self.current() == .escaped_keyword) {
                    self.addError(self.currentSpan(), "escaped reserved word cannot be used as label");
                } else if (self.ctx.is_strict_mode and self.current().isStrictModeReserved()) {
                    self.addError(self.currentSpan(), "reserved word in strict mode cannot be used as label");
                }
                return self.parseLabeledStatement();
            }
        }
        return self.parseExpressionStatement();
    }

    /// labeled statement: label: statement
    fn parseLabeledStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // label
        const label = try self.ast.addNode(.{
            .tag = .identifier_reference,
            .span = self.currentSpan(),
            .data = .{ .string_ref = self.currentSpan() },
        });
        self.advance(); // skip label
        self.advance(); // skip ':'
        const body = try self.parseStatementChecked(false);
        return try self.ast.addNode(.{
            .tag = .labeled_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = label, .right = body, .flags = 0 } },
        });
    }

    /// with statement: with (expr) statement
    /// strict mode에서는 SyntaxError (D054)
    fn parseWithStatement(self: *Parser) ParseError2!NodeIndex {
        if (self.ctx.is_strict_mode) {
            self.addError(self.currentSpan(), "'with' is not allowed in strict mode");
        }
        const start = self.currentSpan().start;
        self.advance(); // skip 'with'
        self.expect(.l_paren);
        const obj = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseStatementChecked(false);
        return try self.ast.addNode(.{
            .tag = .with_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = obj, .right = body, .flags = 0 } },
        });
    }

    fn parseVariableDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const kind_flags: u32 = switch (self.current()) {
            .kw_var => 0,
            .kw_let => 1,
            .kw_const => 2,
            else => 0,
        };
        self.advance(); // skip var/let/const

        // let/const 선언에서 바인딩 이름 'let'은 금지 (ECMAScript 14.3.1.1)
        // 'let let = 1' → SyntaxError (non-strict에서도)
        if (kind_flags != 0 and self.current() == .kw_let) {
            self.addError(self.currentSpan(), "'let' is not allowed as variable name in lexical declaration");
        }

        const scratch_top = self.saveScratch();
        while (true) {
            const decl = try self.parseVariableDeclarator();
            // const without initializer → SyntaxError (ECMAScript 14.3.1)
            // for-in/for-of에서는 const 이니셜라이저 불필요 (for (const x of ...))
            // TS declare에서도 불필요 (declare const x: number)
            if (kind_flags == 2 and !decl.isNone() and !self.ctx.for_loop_init and !self.ctx.in_ambient) {
                const decl_node = self.ast.getNode(decl);
                if (decl_node.tag == .variable_declarator) {
                    const init_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[decl_node.data.extra + 2]);
                    if (init_idx.isNone()) {
                        self.addError(decl_node.span, "const declarations must be initialized");
                    }
                }
            }
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

    fn parseVariableDeclarator(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // 바인딩 패턴 (identifier, [array], {object} destructuring)
        // 주의: parseBindingPattern이 아닌 parseBindingName을 사용.
        // parseBindingPattern은 `=`를 default value로 소비하지만,
        // variable declarator에서 `=`는 initializer이므로 여기서 소비하면 안 됨.
        const name = try self.parseBindingName();

        // TS 타입 어노테이션 (: Type)
        const type_ann = try self.tryParseTypeAnnotation();

        // 이니셜라이저 — `in` 연산자를 복원한다 (ECMAScript: Initializer[+In]).
        // for 초기화절에서 allow_in=false여도, 이니셜라이저 안에서는 `in`이 연산자로 동작해야 한다.
        var init_expr = NodeIndex.none;
        if (self.eat(.eq)) {
            const init_saved = self.enterAllowInContext(true);
            init_expr = try self.parseAssignmentExpression();
            self.restoreContext(init_saved);
        }

        // name, type_ann, init_expr → extra_data
        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_ann));
        _ = try self.ast.addExtra(@intFromEnum(init_expr));

        return try self.ast.addNode(.{
            .tag = .variable_declarator,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseReturnStatement(self: *Parser) ParseError2!NodeIndex {
        // return은 함수 안에서만 허용
        if (!self.ctx.in_function) {
            self.addError(self.currentSpan(), "'return' outside of function");
        }
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
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }

    fn parseIfStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'if'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        const consequent = try self.parseStatementChecked(false);

        var alternate = NodeIndex.none;
        if (self.eat(.kw_else)) {
            alternate = try self.parseStatementChecked(false);
        }

        return try self.ast.addNode(.{
            .tag = .if_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = test_expr, .b = consequent, .c = alternate } },
        });
    }

    fn parseWhileStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'while'
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
        });
    }

    fn parseDoWhileStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'do'
        const body = try self.parseLoopBody();
        self.expect(.kw_while);
        self.expect(.l_paren);
        const test_expr = try self.parseExpression();
        self.expect(.r_paren);
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .do_while_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = test_expr, .right = body, .flags = 0 } },
        });
    }

    fn parseForStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'for'

        // for await (...) — async iteration
        // TODO: for-of 노드에 await 플래그 전달 (현재 파서 통과만 보장)
        const _is_await = self.eat(.kw_await);
        _ = _is_await;

        self.expect(.l_paren);

        // for문의 init 부분 파싱
        // for(init; ...) or for(left in/of right)
        if (self.current() == .semicolon) {
            // for(; ...) — 빈 init
            self.advance();
            return self.parseForRest(start, NodeIndex.none);
        }

        // for 초기화절에서는 `in` 연산자를 비활성화하고 for_loop_init을 설정한다.
        // for_loop_init: const without init 체크 스킵 (for-in/for-of에서는 init 불필요)
        const for_saved = self.enterAllowInContext(false);
        self.ctx.for_loop_init = true;

        if (self.current() == .kw_var or self.current() == .kw_let or self.current() == .kw_const) {
            const init_expr = try self.parseVariableDeclaration();
            self.restoreContext(for_saved);
            // parseVariableDeclaration이 세미콜론을 소비했으면 for(;;)
            // 'in' 또는 'of'가 보이면 for-in/for-of
            if (self.current() == .kw_in or self.current() == .kw_of) {
                // for-in/for-of에서 let/const 여러 바인딩 금지 (ECMAScript 14.7.5.1)
                if (!init_expr.isNone()) {
                    const init_node = self.ast.getNode(init_expr);
                    if (init_node.tag == .variable_declaration) {
                        const decl_len = self.ast.extra_data.items[init_node.data.extra + 2];
                        if (decl_len > 1) {
                            self.addError(init_node.span, "only a single variable declaration is allowed in a for-in/for-of statement");
                        }
                    }
                }
                if (self.current() == .kw_in) {
                    return self.parseForIn(start, init_expr);
                }
                return self.parseForOf(start, init_expr);
            }
            return self.parseForRest(start, init_expr);
        }

        // 일반 표현식 init
        const init_expr = try self.parseExpression();
        self.restoreContext(for_saved);
        if (self.current() == .kw_in) {
            // for-in LHS가 assignment destructuring이면 rest-init 검증
            self.checkRestInitInAssignmentPattern(init_expr);
            return self.parseForIn(start, init_expr);
        }
        if (self.current() == .kw_of) {
            // for-of LHS가 assignment destructuring이면 rest-init 검증
            self.checkRestInitInAssignmentPattern(init_expr);
            return self.parseForOf(start, init_expr);
        }
        _ = self.eat(.semicolon);
        return self.parseForRest(start, init_expr);
    }

    /// for(init; test; update) body — 나머지 파싱
    fn parseForRest(self: *Parser, start: u32, init_expr: NodeIndex) ParseError2!NodeIndex {
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
        const body = try self.parseLoopBody();

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
    fn parseForIn(self: *Parser, start: u32, left: NodeIndex) ParseError2!NodeIndex {
        self.advance(); // skip 'in'
        const right = try self.parseExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .for_in_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// for(left of right) body
    fn parseForOf(self: *Parser, start: u32, left: NodeIndex) ParseError2!NodeIndex {
        self.advance(); // skip 'of'
        const right = try self.parseAssignmentExpression();
        self.expect(.r_paren);
        const body = try self.parseLoopBody();

        return try self.ast.addNode(.{
            .tag = .for_of_statement,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .ternary = .{ .a = left, .b = right, .c = body } },
        });
    }

    /// break, continue, debugger 등 키워드 + 세미콜론만으로 구성된 단순 문.
    fn parseSimpleStatement(self: *Parser, tag: Tag) ParseError2!NodeIndex {
        const keyword_span = self.currentSpan();
        const start = keyword_span.start;
        self.advance(); // skip break/continue/debugger

        // break/continue 뒤에 줄바꿈 없이 identifier가 오면 label로 소비
        var label = NodeIndex.none;
        if ((tag == .break_statement or tag == .continue_statement) and
            self.current() == .identifier and !self.scanner.token.has_newline_before)
        {
            label = try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = self.currentSpan(),
                .data = .{ .string_ref = self.currentSpan() },
            });
            self.advance();
        }

        // continue → label 유무와 관계없이 loop 안에서만 허용
        if (tag == .continue_statement and !self.ctx.in_loop) {
            self.addError(keyword_span, "'continue' outside of loop");
        }
        // break → label이 없을 때만 loop 또는 switch 필요
        // label이 있는 break는 labelled statement 안에서 유효 (loop/switch 불필요)
        if (tag == .break_statement and label.isNone() and !self.ctx.in_loop and !self.ctx.in_switch) {
            self.addError(keyword_span, "'break' outside of loop or switch");
        }

        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = tag,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = label, .flags = 0 } },
        });
    }

    fn parseSwitchStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'switch'
        self.expect(.l_paren);
        const discriminant = try self.parseExpression();
        self.expect(.r_paren);
        self.expect(.l_curly);

        const saved = self.ctx;
        self.ctx.in_switch = true;

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const case_node = try self.parseSwitchCase();
            try self.scratch.append(case_node);
        }

        self.ctx = saved;

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

    fn parseSwitchCase(self: *Parser) ParseError2!NodeIndex {
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
            return try self.ast.addNode(.{ .tag = .invalid, .span = err_span, .data = .{ .none = 0 } });
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

    fn parseThrowStatement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'throw'
        // ECMAScript 14.14: throw [no LineTerminator here] Expression
        if (self.scanner.token.has_newline_before) {
            self.addError(.{ .start = start, .end = self.currentSpan().start }, "no line break is allowed after 'throw'");
        }
        const arg = try self.parseExpression();
        const end = self.currentSpan().end;
        _ = self.eat(.semicolon);
        return try self.ast.addNode(.{
            .tag = .throw_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
        });
    }

    fn parseTryStatement(self: *Parser) ParseError2!NodeIndex {
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

    fn parseCatchClause(self: *Parser) ParseError2!NodeIndex {
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
            .data = .{ .binary = .{ .left = param, .right = body, .flags = 0 } },
        });
    }

    fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionDeclarationWithFlags(0);
    }

    fn parseFunctionDeclarationWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // generator: function* name()
        var flags = extra_flags;
        if (self.eat(.star)) {
            flags |= ast_mod.FunctionFlags.is_generator;
        }

        // 함수 이름
        const name = try self.parseBindingIdentifier();

        // 파라미터
        self.expect(.l_paren);
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(param);
            // rest parameter 뒤에 comma가 오면 에러 (ECMAScript 14.1)
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);

        // TS 리턴 타입 어노테이션
        const return_type = try self.tryParseReturnType();

        // 함수 본문 — 컨텍스트 저장/복원
        const saved_ctx = self.enterFunctionContext((flags & 0x01) != 0, (flags & 0x02) != 0);
        self.ctx.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBody();
        self.restoreContext(saved_ctx);

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
    fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
        const peek = self.peekNext();
        // async [no LineTerminator here] function → async function declaration
        if (peek.kind == .kw_function and !peek.has_newline_before) {
            self.advance(); // skip 'async'
            return self.parseFunctionDeclarationWithFlags(ast_mod.FunctionFlags.is_async);
        }
        // async 뒤에 줄바꿈이 있거나 function이 아니면 → expression statement
        return self.parseExpressionStatement();
    }

    fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionExpressionWithFlags(0);
    }

    fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'function'

        // generator: function* () {}
        var flags: u32 = extra_flags;
        if (self.eat(.star)) {
            flags |= ast_mod.FunctionFlags.is_generator;
        }

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
            if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
                self.addError(self.currentSpan(), "rest parameter must be last formal parameter");
            }
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);

        // TS 리턴 타입 어노테이션
        _ = try self.tryParseReturnType();

        // 함수 본문 — 컨텍스트 저장/복원
        const saved_ctx = self.enterFunctionContext((flags & 0x01) != 0, (flags & 0x02) != 0);
        self.ctx.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBody();
        self.restoreContext(saved_ctx);

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

    fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseClassWithDecorators(.class_declaration, .{ .start = 0, .len = 0 });
    }

    fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
        return self.parseClassWithDecorators(.class_expression, .{ .start = 0, .len = 0 });
    }

    /// class 선언/표현식을 파싱한다.
    /// extra = [name, super_class, body, type_params, implements_start, implements_len, deco_start, deco_len]
    fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'class'

        // 클래스 이름 (선언은 필수, 표현식은 선택)
        var name = NodeIndex.none;
        if (self.current() == .identifier) {
            name = try self.parseBindingIdentifier();
        }

        // TS 제네릭 파라미터: class Foo<T> { }
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        // extends 절 (선택)
        var super_class = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            super_class = try self.parseAssignmentExpression();
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
        const class_ctx_saved = self.ctx;
        self.ctx.has_super_class = !super_class.isNone();
        const body = try self.parseClassBody();
        self.ctx = class_ctx_saved;

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

    fn parseClassBody(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.expect(.l_curly);

        // class body 안에서는 in_class=true (super 허용 등)
        const class_saved = self.ctx;
        self.ctx.in_class = true;

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

        self.ctx = class_saved;

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

    fn parseClassMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // 데코레이터 (class member 앞)
        while (self.current() == .at) {
            _ = try self.parseDecorator(); // TODO: 멤버에 연결 (BACKLOG)
        }

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
                self.advance(); // skip 'static'
                const body = try self.parseBlockStatement();
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

        // get/set (선택)
        if (self.current() == .kw_get and self.peekNextKind() != .l_paren) {
            flags |= 0x02; // getter
            self.advance();
        } else if (self.current() == .kw_set and self.peekNextKind() != .l_paren) {
            flags |= 0x04; // setter
            self.advance();
        }

        // async (선택): async method() {}
        if (self.current() == .kw_async and self.peekNextKind() != .l_paren and
            !self.scanner.token.has_newline_before)
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
            self.expect(.l_paren);
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
                self.ctx.allow_super_property = true;
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
                        if (self.ctx.has_super_class) {
                            self.ctx.allow_super_call = true;
                        }
                    }
                }
                self.ctx.has_simple_params = self.checkSimpleParams(param_top);
                self.checkDuplicateParams(param_top);
                body = try self.parseFunctionBody();
                self.restoreContext(saved_ctx);
            } else {
                _ = self.eat(.semicolon);
            }
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
            const field_saved = self.ctx;
            self.ctx.in_class_field = true;
            init_val = try self.parseAssignmentExpression();
            self.ctx = field_saved;
        }
        _ = self.eat(.semicolon);

        return try self.ast.addNode(.{
            .tag = .property_definition,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = init_val, .flags = flags } },
        });
    }

    const PeekResult = struct { kind: Kind, has_newline_before: bool };

    /// 스캐너 상태를 저장한다. lookahead 후 restoreState로 되돌릴 때 사용.
    const ScannerState = struct {
        current: u32,
        start: u32,
        token: Token,
        line: u32,
        line_start: u32,
        brace_depth: u32,
        prev_token_kind: Kind,
        template_depth_len: usize,
    };

    fn saveState(self: *const Parser) ScannerState {
        return .{
            .current = self.scanner.current,
            .start = self.scanner.start,
            .token = self.scanner.token,
            .line = self.scanner.line,
            .line_start = self.scanner.line_start,
            .brace_depth = self.scanner.brace_depth,
            .prev_token_kind = self.scanner.prev_token_kind,
            .template_depth_len = self.scanner.template_depth_stack.items.len,
        };
    }

    fn restoreState(self: *Parser, s: ScannerState) void {
        self.scanner.current = s.current;
        self.scanner.start = s.start;
        self.scanner.token = s.token;
        self.scanner.line = s.line;
        self.scanner.line_start = s.line_start;
        self.scanner.brace_depth = s.brace_depth;
        self.scanner.prev_token_kind = s.prev_token_kind;
        // template_depth_stack은 lookahead 중 push(grow) 또는 pop(shrink) 가능.
        // pop으로 줄어든 경우 saved 길이가 현재보다 크지만, capacity 내이므로
        // items.len 직접 설정으로 안전하게 복구할 수 있다.
        if (s.template_depth_len <= self.scanner.template_depth_stack.items.len) {
            self.scanner.template_depth_stack.shrinkRetainingCapacity(s.template_depth_len);
        } else {
            self.scanner.template_depth_stack.items.len = s.template_depth_len;
        }
    }

    /// 다음 토큰의 Kind와 줄바꿈 여부를 미리 본다 (현재 토큰을 소비하지 않음).
    fn peekNext(self: *Parser) PeekResult {
        const saved = self.saveState();

        self.scanner.next();
        const result = PeekResult{
            .kind = self.scanner.token.kind,
            .has_newline_before = self.scanner.token.has_newline_before,
        };

        self.restoreState(saved);
        return result;
    }

    /// peekNext의 Kind만 반환하는 편의 함수.
    fn peekNextKind(self: *Parser) Kind {
        return self.peekNext().kind;
    }

    /// JSX element 모드에서 다음 토큰의 Kind를 미리 본다 (현재 토큰을 소비하지 않음).
    /// JSX children 파싱 중 '<' 다음이 '/'인지 판별할 때 사용.
    /// normal 모드에서는 '/'가 regex로 해석될 수 있으므로 JSX 전용 peek이 필요하다.
    fn peekNextKindJSX(self: *Parser) Kind {
        const saved = self.saveState();
        self.scanner.nextInsideJSXElement();
        const peek_kind = self.scanner.token.kind;
        self.restoreState(saved);
        return peek_kind;
    }

    // ================================================================
    // Import / Export 파싱
    // ================================================================

    fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // ECMAScript 15.2: import 선언은 module의 top-level에서만 허용
        if (!self.is_module) {
            self.addError(self.currentSpan(), "'import' declaration is only allowed in module code");
        } else if (!self.ctx.is_top_level) {
            self.addError(self.currentSpan(), "'import' declaration must be at the top level");
        }
        self.advance(); // skip 'import'

        // import defer / import source — Stage 3 proposals
        // defer/source를 스킵하고 나머지는 일반 import로 처리
        var has_phase_modifier = false;
        if (self.current() == .kw_defer or
            (self.current() == .identifier and
                std.mem.eql(u8, self.ast.source[self.currentSpan().start..self.currentSpan().end], "source")))
        {
            has_phase_modifier = true;
            self.advance(); // skip defer/source
        }

        // import "module" — side-effect import
        if (self.current() == .string_literal) {
            if (has_phase_modifier) {
                self.addError(self.currentSpan(), "'import defer/source' requires a binding");
            }
            const source_node = try self.parseModuleSource();
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .import_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = source_node, .flags = 1 } }, // flags=1: side-effect import
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
                .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
            });
            // 후속 .then() 등의 member/call 체이닝 처리
            _ = self.eat(.semicolon);
            return try self.ast.addNode(.{
                .tag = .expression_statement,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = import_expr, .flags = 0 } },
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

    fn parseImportSpecifier(self: *Parser) ParseError2!NodeIndex {
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
            .data = .{ .binary = .{ .left = imported, .right = local, .flags = 0 } },
        });
    }

    fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // ECMAScript 15.2: export 선언은 module의 top-level에서만 허용
        if (!self.is_module) {
            self.addError(self.currentSpan(), "'export' declaration is only allowed in module code");
        } else if (!self.ctx.is_top_level) {
            self.addError(self.currentSpan(), "'export' declaration must be at the top level");
        }
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
                .data = .{ .unary = .{ .operand = decl, .flags = 0 } },
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
                .data = .{ .binary = .{ .left = exported_name, .right = source_node, .flags = 0 } },
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

            // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
            const extra_start = try self.ast.addExtras(&.{
                @intFromEnum(NodeIndex.none), // declaration 없음
                specifiers.start,
                specifiers.len,
                @intFromEnum(source_node),
            });

            return try self.ast.addNode(.{
                .tag = .export_named_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // export var/let/const/function/class
        // extra_data layout: [declaration, specifiers_start, specifiers_len, source]
        const decl = try self.parseStatement();
        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(decl),
            0, // specifiers_start (사용 안 함)
            0, // specifiers_len = 0
            @intFromEnum(NodeIndex.none), // source 없음
        });
        return try self.ast.addNode(.{
            .tag = .export_named_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseExportSpecifier(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        const local = try self.parseIdentifierName();

        var exported = local;
        if (self.eat(.kw_as)) {
            exported = try self.parseIdentifierName();
        }

        return try self.ast.addNode(.{
            .tag = .export_specifier,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = local, .right = exported, .flags = 0 } },
        });
    }

    fn parseModuleSource(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .string_literal) {
            self.advance();
            // import attributes: with { type: 'json' } 또는 assert { type: 'json' }
            self.skipImportAttributes();
            return try self.ast.addNode(.{
                .tag = .string_literal,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "module source string expected");
        return NodeIndex.none;
    }

    /// import attributes (with/assert { ... })를 건너뛴다.
    /// AST에 저장하지 않고 소비만 한다 (트랜스포머에서 필요 시 추가).
    fn skipImportAttributes(self: *Parser) void {
        // with { ... } 또는 assert { ... }
        if ((self.current() == .kw_with or self.current() == .kw_assert) and
            !self.scanner.token.has_newline_before)
        {
            self.advance(); // skip with/assert
            if (self.current() == .l_curly) {
                self.advance(); // skip {
                while (self.current() != .r_curly and self.current() != .eof) {
                    self.advance(); // key
                    _ = self.eat(.colon);
                    if (self.current() != .r_curly and self.current() != .eof) {
                        self.advance(); // value
                    }
                    _ = self.eat(.comma);
                }
                _ = self.eat(.r_curly);
            }
        }
    }

    // ================================================================
    // Expression 파싱 (Pratt parser / precedence climbing)
    // ================================================================

    /// 콤마 연산자(sequence expression)를 포함한 최상위 표현식 파싱.
    /// ECMAScript: Expression = AssignmentExpression (',' AssignmentExpression)*
    /// 콤마가 없으면 단일 AssignmentExpression을 그대로 반환하고,
    /// 콤마가 있으면 sequence_expression 노드로 감싼다.
    fn parseExpression(self: *Parser) ParseError2!NodeIndex {
        const first = try self.parseAssignmentExpression();

        // 콤마가 없으면 단순 표현식
        if (self.current() != .comma) return first;

        // 콤마 연산자 → sequence expression
        const scratch_top = self.saveScratch();
        try self.scratch.append(first);
        while (self.eat(.comma)) {
            // trailing comma: 콤마 뒤에 )가 오면 arrow function 파라미터 trailing comma
            if (self.current() == .r_paren) break;
            const elem = try self.parseAssignmentExpression();
            try self.scratch.append(elem);
        }
        const first_span = self.ast.getNode(first).span;
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        return try self.ast.addNode(.{
            .tag = .sequence_expression,
            .span = .{ .start = first_span.start, .end = self.currentSpan().start },
            .data = .{ .list = list },
        });
    }

    /// arrow function의 body를 파싱한다.
    /// arrow function은 함수이므로 in_function=true, loop/switch 리셋.
    /// block body면 parseFunctionBody(), expression body면 parseAssignmentExpression().
    fn parseArrowBody(self: *Parser, is_async: bool) ParseError2!NodeIndex {
        // arrow function은 generator가 될 수 없으므로 is_generator=false
        const saved_ctx = self.enterFunctionContext(is_async, false);
        const body = if (self.current() == .l_curly)
            try self.parseFunctionBody()
        else
            try self.parseAssignmentExpression();
        self.restoreContext(saved_ctx);
        return body;
    }

    fn parseAssignmentExpression(self: *Parser) ParseError2!NodeIndex {
        // async arrow function 감지 (2가지 형태)
        if (self.current() == .kw_async) {
            const async_span = self.currentSpan();
            const peek = self.peekNext();

            if (!peek.has_newline_before) {
                // 형태 1: async x => body (단순 식별자)
                if (peek.kind == .identifier or (peek.kind.isKeyword() and !peek.kind.isReservedKeyword())) {
                    const saved = self.saveState();
                    self.advance(); // skip 'async'
                    const id_span = self.currentSpan();
                    self.advance(); // skip identifier
                    if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                        self.advance(); // skip =>
                        const param = try self.ast.addNode(.{
                            .tag = .binding_identifier,
                            .span = id_span,
                            .data = .{ .string_ref = id_span },
                        });
                        const body = try self.parseArrowBody(true);
                        return try self.ast.addNode(.{
                            .tag = .arrow_function_expression,
                            .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = param, .right = body, .flags = 0x01 } },
                        });
                    }
                    self.restoreState(saved);
                }

                // 형태 2: async (...) => body (괄호 형태)
                // async () => {} — 빈 파라미터도 포함
                if (peek.kind == .l_paren) {
                    const saved = self.saveState();
                    self.advance(); // skip 'async'

                    // () 빈 파라미터 체크
                    if (self.current() == .l_paren and self.peekNextKind() == .r_paren) {
                        self.advance(); // skip (
                        self.advance(); // skip )
                        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                            self.advance(); // skip =>
                            const body = try self.parseArrowBody(true);
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .binary = .{ .left = .none, .right = body, .flags = 0x01 } },
                            });
                        }
                        self.restoreState(saved);
                    } else {
                        // 괄호를 expression으로 파싱 (parenthesized_expression)
                        const params_expr = try self.parseConditionalExpression();
                        if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                            self.checkRestInitInArrowParams(params_expr);
                            self.advance(); // skip =>
                            const body = try self.parseArrowBody(true);
                            return try self.ast.addNode(.{
                                .tag = .arrow_function_expression,
                                .span = .{ .start = async_span.start, .end = self.currentSpan().start },
                                .data = .{ .binary = .{ .left = params_expr, .right = body, .flags = 0x01 } },
                            });
                        }
                        self.restoreState(saved);
                    }
                }
            }
        }

        // 단일 식별자 + => → arrow function (간단한 형태: x => x + 1)
        if (self.current() == .identifier) {
            const id_span = self.currentSpan();
            const saved = self.saveState();

            self.advance(); // skip identifier
            if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                // identifier => body
                self.advance(); // skip =>
                const param = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = id_span,
                    .data = .{ .string_ref = id_span },
                });
                const body = try self.parseArrowBody(false);

                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = id_span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = param, .right = body, .flags = 0 } },
                });
            }

            // arrow가 아님 → 되돌리기
            self.restoreState(saved);
        }

        // () => body — 빈 파라미터 arrow function
        if (self.current() == .l_paren and self.peekNextKind() == .r_paren) {
            const arrow_start = self.currentSpan().start;
            const saved = self.saveState();
            self.advance(); // skip (
            self.advance(); // skip )
            if (self.current() == .arrow and !self.scanner.token.has_newline_before) {
                self.advance(); // skip =>
                const body = try self.parseArrowBody(false);
                return try self.ast.addNode(.{
                    .tag = .arrow_function_expression,
                    .span = .{ .start = arrow_start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = .none, .right = body, .flags = 0 } },
                });
            }
            self.restoreState(saved);
        }

        const left = try self.parseConditionalExpression();

        // => 를 만나면 arrow function (괄호 형태)
        // left가 parenthesized_expression이면 파라미터 리스트로 취급
        if (self.current() == .arrow) {
            // arrow 파라미터에서 rest-init 검증 (ECMAScript: ArrowFormalParameters)
            self.checkRestInitInArrowParams(left);
            const left_start = self.ast.getNode(left).span.start;
            self.advance(); // skip =>
            const body = try self.parseArrowBody(false);

            return try self.ast.addNode(.{
                .tag = .arrow_function_expression,
                .span = .{ .start = left_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = body, .flags = 0 } },
            });
        }

        if (self.current().isAssignment()) {
            // assignment target 검증 (ECMAScript 13.15.1)
            if (!self.isValidAssignmentTarget(left)) {
                self.addError(self.ast.getNode(left).span, "invalid assignment target");
            }
            // assignment destructuring에서 rest element에 initializer 금지
            self.checkRestInitInAssignmentPattern(left);
            // strict mode: eval/arguments에 할당 금지 (ECMAScript 13.15.1)
            if (self.ctx.is_strict_mode) {
                self.checkStrictAssignmentTarget(left);
            }
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

    fn parseConditionalExpression(self: *Parser) ParseError2!NodeIndex {
        const expr = try self.parseBinaryExpression(0);

        if (self.eat(.question)) {
            const expr_start = self.ast.getNode(expr).span.start;
            // 조건 연산자의 consequent/alternate에서는 `in` 연산자 항상 허용
            const cond_saved = self.enterAllowInContext(true);
            const consequent = try self.parseAssignmentExpression();
            self.expect(.colon);
            const alternate = try self.parseAssignmentExpression();
            self.restoreContext(cond_saved);
            return try self.ast.addNode(.{
                .tag = .conditional_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .ternary = .{ .a = expr, .b = consequent, .c = alternate } },
            });
        }

        return expr;
    }

    /// 이항 연산자를 precedence climbing으로 파싱.
    fn parseBinaryExpression(self: *Parser, min_prec: u8) ParseError2!NodeIndex {
        var left = try self.parseUnaryExpression();

        // ?? 와 &&/|| 혼합 감지용 — 괄호 없이 혼합하면 SyntaxError
        var has_coalesce = false;
        var has_logical_or_and = false;

        while (true) {
            // allow_in이 false면 `in`을 이항 연산자로 취급하지 않는다.
            // ECMAScript 13.7.4: for 초기화절에서 `in`은 for-in 키워드이지 연산자가 아니다.
            if (self.current() == .kw_in and !self.ctx.allow_in) break;

            const prec = getBinaryPrecedence(self.current());
            if (prec == 0 or prec <= min_prec) break;

            // ECMAScript 12.6: unary expression ** exponentiation → SyntaxError
            // delete/void/typeof/+/-/~/! 의 결과에 **를 적용할 수 없음
            if (self.current() == .star2 and !left.isNone()) {
                const left_tag = self.ast.getNode(left).tag;
                if (left_tag == .unary_expression) {
                    self.addError(self.currentSpan(), "unary expression cannot be the left operand of '**'");
                }
            }

            const left_start = self.ast.getNode(left).span.start;
            const op_kind = self.current();
            const is_logical = (op_kind == .amp2 or op_kind == .pipe2 or op_kind == .question2);

            // ?? 와 &&/|| 혼합 감지 (ECMAScript: 괄호 없이 혼합 금지)
            if (op_kind == .question2) {
                if (has_logical_or_and) {
                    self.addError(self.currentSpan(), "cannot mix '??' with '&&' or '||' without parentheses");
                }
                has_coalesce = true;
            } else if (op_kind == .amp2 or op_kind == .pipe2) {
                if (has_coalesce) {
                    self.addError(self.currentSpan(), "cannot mix '??' with '&&' or '||' without parentheses");
                }
                has_logical_or_and = true;
            }

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

    fn parseUnaryExpression(self: *Parser) ParseError2!NodeIndex {
        const kind = self.current();
        switch (kind) {
            .bang, .tilde, .minus, .plus, .kw_typeof, .kw_void, .kw_delete => {
                const start = self.currentSpan().start;
                const is_delete = kind == .kw_delete;
                self.advance();
                const operand = try self.parseUnaryExpression();
                // strict mode: delete identifier → SyntaxError (ECMAScript 12.5.3.1)
                // delete of private field → always SyntaxError (ECMAScript 13.5.1.1)
                // delete (this.#x), delete this?.#x 도 포함
                if (is_delete and !operand.isNone()) {
                    var del_target = operand;
                    // 괄호 unwrap
                    while (!del_target.isNone()) {
                        const dt = self.ast.getNode(del_target);
                        if (dt.tag == .parenthesized_expression) {
                            del_target = dt.data.unary.operand;
                        } else break;
                    }
                    if (!del_target.isNone()) {
                        const del_node = self.ast.getNode(del_target);
                        if (del_node.tag == .static_member_expression or
                            del_node.tag == .computed_member_expression or
                            del_node.tag == .private_field_expression)
                        {
                            const right_idx = del_node.data.binary.right;
                            if (!right_idx.isNone() and @intFromEnum(right_idx) < self.ast.nodes.items.len) {
                                if (self.ast.getNode(right_idx).tag == .private_identifier) {
                                    self.addError(del_node.span, "private fields cannot be deleted");
                                }
                            }
                        }
                    }
                }
                // delete (x) 도 괄호를 통과하여 체크
                if (is_delete and self.ctx.is_strict_mode and !operand.isNone()) {
                    var target = operand;
                    while (!target.isNone()) {
                        const t = self.ast.getNode(target);
                        if (t.tag == .identifier_reference) {
                            self.addError(t.span, "delete of an identifier is not allowed in strict mode");
                            break;
                        } else if (t.tag == .parenthesized_expression) {
                            target = t.data.unary.operand;
                        } else break;
                    }
                }
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
                // ++/-- operand는 유효한 assignment target이어야 함
                if (!self.isValidAssignmentTarget(operand)) {
                    self.addError(self.ast.getNode(operand).span, "invalid assignment target");
                }
                if (self.ctx.is_strict_mode) self.checkStrictAssignmentTarget(operand);
                return try self.ast.addNode(.{
                    .tag = .update_expression,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = @intFromEnum(kind) } },
                });
            },
            .kw_await => {
                // async 함수 안 또는 module mode(top-level await)에서 await_expression으로 파싱.
                // 그 외에는 식별자로 fallthrough.
                if (self.ctx.in_async or self.is_module) {
                    const start = self.currentSpan().start;
                    self.advance();
                    const operand = try self.parseUnaryExpression();
                    return try self.ast.addNode(.{
                        .tag = .await_expression,
                        .span = .{ .start = start, .end = self.currentSpan().start },
                        .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                    });
                }
                // async 밖 + script mode에서는 식별자로 파싱
                return self.parsePostfixExpression();
            },
            .kw_yield => {
                // generator 안에서만 yield_expression, 밖에서는 식별자로 fallthrough
                if (self.ctx.in_generator) {
                    const start = self.currentSpan().start;
                    self.advance();
                    // yield* delegate — * 전에 줄바꿈이 있으면 delegate 아님
                    var flags: u16 = 0;
                    if (!self.scanner.token.has_newline_before and self.eat(.star)) {
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
                }
                // generator 밖에서는 식별자로 파싱 (strict mode에서는 에러이지만 파싱은 계속)
                return self.parsePostfixExpression();
            },
            else => return self.parsePostfixExpression(),
        }
    }

    fn parsePostfixExpression(self: *Parser) ParseError2!NodeIndex {
        var expr = try self.parseCallExpression();

        // 후위 ++/--
        if ((self.current() == .plus2 or self.current() == .minus2) and
            !self.scanner.token.has_newline_before)
        {
            // ++/-- operand는 유효한 assignment target이어야 함
            if (!self.isValidAssignmentTarget(expr)) {
                self.addError(self.ast.getNode(expr).span, "invalid assignment target");
            }
            if (self.ctx.is_strict_mode) self.checkStrictAssignmentTarget(expr);
            const expr_start = self.ast.getNode(expr).span.start;
            const kind = self.current();
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .update_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = @as(u16, @intFromEnum(kind)) | 0x100 } }, // 0x100 = postfix
            });
        }

        // TS: non-null assertion (expr!)
        if (self.current() == .bang and !self.scanner.token.has_newline_before) {
            const expr_start = self.ast.getNode(expr).span.start;
            self.advance();
            expr = try self.ast.addNode(.{
                .tag = .ts_non_null_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }

        // TS: as Type / satisfies Type (체이닝 가능: x as A as B)
        while (self.current() == .kw_as or self.current() == .kw_satisfies) {
            const expr_start = self.ast.getNode(expr).span.start;
            const is_satisfies = self.current() == .kw_satisfies;
            self.advance();
            const ty = try self.parseType();
            expr = try self.ast.addNode(.{
                .tag = if (is_satisfies) .ts_satisfies_expression else .ts_as_expression,
                .span = .{ .start = expr_start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = expr, .right = ty, .flags = 0 } },
            });
        }

        return expr;
    }

    fn parseCallExpression(self: *Parser) ParseError2!NodeIndex {
        var expr = try self.parsePrimaryExpression();
        var after_optional_chain = false;

        while (true) {
            const expr_start = self.ast.getNode(expr).span.start;
            switch (self.current()) {
                .l_paren => {
                    // super() 호출은 constructor에서만 허용
                    if (self.ast.getNode(expr).tag == .super_expression and !self.ctx.allow_super_call) {
                        self.addError(self.ast.getNode(expr).span, "'super()' is only allowed in a class constructor");
                    }
                    // 함수 호출
                    self.advance();
                    const arg_list = try self.parseArgumentList();
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
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .l_bracket => {
                    // 계산된 멤버 접근: a[b] — `in` 연산자 허용 (ECMAScript: [+In])
                    self.advance();
                    const cm_saved = self.enterAllowInContext(true);
                    const prop = try self.parseExpression();
                    self.restoreContext(cm_saved);
                    self.expect(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .question_dot => {
                    // optional chaining: a?.b, a?.[b], a?.()
                    self.advance(); // skip ?.
                    if (self.current() == .l_bracket) {
                        // a?.[expr] — `in` 연산자 허용 (ECMAScript: [+In])
                        self.advance();
                        const oc_saved = self.enterAllowInContext(true);
                        const prop = try self.parseExpression();
                        self.restoreContext(oc_saved);
                        self.expect(.r_bracket);
                        expr = try self.ast.addNode(.{
                            .tag = .computed_member_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 1 } }, // 1 = optional
                        });
                    } else if (self.current() == .l_paren) {
                        // a?.()
                        self.advance();
                        const arg_list = try self.parseArgumentList();
                        expr = try self.ast.addNode(.{
                            .tag = .call_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len | 0x8000) } }, // 0x8000 = optional
                        });
                    } else {
                        // a?.b
                        const prop = try self.parseIdentifierName();
                        expr = try self.ast.addNode(.{
                            .tag = .static_member_expression,
                            .span = .{ .start = expr_start, .end = self.currentSpan().start },
                            .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 1 } }, // 1 = optional
                        });
                    }
                    after_optional_chain = true;
                    continue;
                },
                .no_substitution_template, .template_head => {
                    // tagged template 금지: a?.b`template` (ECMAScript 12.3.1.1)
                    if (after_optional_chain) {
                        self.addError(self.currentSpan(), "tagged template cannot be used in optional chain");
                    }
                    // tagged template: expr`text` 또는 expr`text${...}...`
                    const tmpl = if (self.current() == .template_head)
                        try self.parseTemplateLiteral()
                    else blk: {
                        const tmpl_span = self.currentSpan();
                        self.advance();
                        break :blk try self.ast.addNode(.{
                            .tag = .template_literal,
                            .span = tmpl_span,
                            .data = .{ .none = 0 },
                        });
                    };
                    expr = try self.ast.addNode(.{
                        .tag = .tagged_template_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = tmpl, .flags = 0 } },
                    });
                },
                else => break,
            }
            after_optional_chain = false;
        }

        return expr;
    }

    /// new 표현식의 callee를 파싱한다.
    /// new는 중첩 가능하므로 new를 만나면 재귀한다.
    /// member access (.prop, [expr])만 허용하고 호출 ()은 상위에서 처리.
    fn parseNewCallee(self: *Parser) ParseError2!NodeIndex {
        // ECMAScript: new import(...) 는 금지
        if (self.current() == .kw_import) {
            self.addError(self.currentSpan(), "'import' cannot be used with 'new'");
        }
        if (self.current() == .kw_new) {
            const span = self.currentSpan();
            self.advance(); // skip 'new'
            const callee = try self.parseNewCallee();
            if (self.current() == .l_paren) {
                self.advance();
                const arg_list = try self.parseArgumentList();
                return try self.ast.addNode(.{
                    .tag = .new_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = callee, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                });
            }
            return try self.ast.addNode(.{
                .tag = .new_expression,
                .span = .{ .start = span.start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = callee, .right = NodeIndex.none, .flags = 0 } },
            });
        }

        // primary expression + member chain (호출 제외)
        var expr = try self.parsePrimaryExpression();
        while (true) {
            const expr_start = self.ast.getNode(expr).span.start;
            switch (self.current()) {
                .dot => {
                    self.advance();
                    const prop = try self.parseIdentifierName();
                    expr = try self.ast.addNode(.{
                        .tag = .static_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                .l_bracket => {
                    self.advance();
                    const prop = try self.parseExpression();
                    self.expect(.r_bracket);
                    expr = try self.ast.addNode(.{
                        .tag = .computed_member_expression,
                        .span = .{ .start = expr_start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = expr, .right = prop, .flags = 0 } },
                    });
                },
                else => break,
            }
        }
        return expr;
    }

    fn parsePrimaryExpression(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();

        switch (self.current()) {
            .identifier => {
                // class field 이니셜라이저에서 arguments 사용 금지 (ECMAScript 15.7.1)
                if (self.ctx.in_class_field) {
                    const text = self.ast.source[span.start..span.end];
                    if (std.mem.eql(u8, text, "arguments")) {
                        self.addError(span, "'arguments' is not allowed in class field initializer");
                    }
                }
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
                    .data = .{ .none = 0 },
                });
            },
            .decimal_bigint, .binary_bigint, .octal_bigint, .hex_bigint => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .bigint_literal,
                    .span = span,
                    .data = .{ .none = 0 },
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
                    .data = .{ .none = 0 },
                });
            },
            .kw_null => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .null_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .kw_this => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .this_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .kw_new => {
                // new expression: new Callee(args)
                // new는 중첩 가능: new new Foo()()
                self.advance(); // skip 'new'

                // new.target — 메타 프로퍼티 (함수 안에서만 유효)
                if (self.current() == .dot) {
                    const peek = self.peekNextKind();
                    if (peek == .identifier or peek == .kw_target) {
                        self.advance(); // skip '.'
                        const target_span = self.currentSpan();
                        self.advance(); // skip 'target'
                        // ECMAScript 15.1.1: new.target은 함수 본문 안에서만 허용
                        if (!self.ctx.in_function) {
                            self.addError(.{ .start = span.start, .end = target_span.end }, "'new.target' is not allowed outside of functions");
                        }
                        return try self.ast.addNode(.{
                            .tag = .meta_property,
                            .span = .{ .start = span.start, .end = target_span.end },
                            .data = .{ .none = 1 }, // 1 = new.target (0 = import.meta)
                        });
                    }
                }

                // callee: 재귀적으로 new 또는 primary + member chain
                const callee = try self.parseNewCallee();

                // 인자: (args) — 있으면 소비, 없으면 인자 없는 new (new Foo)
                if (self.current() == .l_paren) {
                    self.advance(); // skip (
                    const arg_list = try self.parseArgumentList();
                    return try self.ast.addNode(.{
                        .tag = .new_expression,
                        .span = .{ .start = span.start, .end = self.currentSpan().start },
                        .data = .{ .binary = .{ .left = callee, .right = @enumFromInt(arg_list.start), .flags = @intCast(arg_list.len) } },
                    });
                }

                // 인자 없는 new: new Foo
                return try self.ast.addNode(.{
                    .tag = .new_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = callee, .right = NodeIndex.none, .flags = 0 } },
                });
            },
            .kw_super => {
                // super expression: super() 또는 super.prop 또는 super[expr]
                // ECMAScript 12.3.7: super는 메서드 안에서만 허용
                // allow_super_property는 메서드 진입 시 true, 일반 함수 진입 시 false로 리셋
                // arrow function은 외부의 allow_super_property를 상속
                if (!self.ctx.allow_super_property and !self.ctx.allow_super_call) {
                    self.addError(span, "'super' is not allowed outside of a method");
                }
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .super_expression,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .l_paren => {
                // 괄호 표현식 또는 arrow function 파라미터 리스트.
                // 괄호 안에서는 `in` 연산자가 항상 허용된다 (ECMAScript: [+In] 컨텍스트).
                self.advance(); // skip (

                // 빈 괄호: () → arrow function의 빈 파라미터 리스트
                if (self.current() == .r_paren) {
                    self.advance(); // skip )
                    return try self.ast.addNode(.{
                        .tag = .parenthesized_expression,
                        .span = .{ .start = span.start, .end = self.currentSpan().start },
                        .data = .{ .none = 0 },
                    });
                }

                const paren_saved = self.enterAllowInContext(true);
                const expr = try self.parseExpression();
                self.restoreContext(paren_saved);
                self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .parenthesized_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            },
            .kw_class => return self.parseClassExpression(),
            .kw_function => return self.parseFunctionExpression(),
            .l_angle => return self.parseJSXElement(),
            .kw_import => {
                self.advance(); // skip 'import'
                if (self.current() == .dot) {
                    self.advance(); // skip '.'
                    const prop_span = self.currentSpan();
                    const prop_name = try self.parseIdentifierName();
                    _ = prop_name;

                    // import.meta — module code에서만 허용
                    // import.source(...), import.defer(...) — script에서도 허용 (dynamic import)
                    const prop_text = self.ast.source[prop_span.start..prop_span.end];
                    if (std.mem.eql(u8, prop_text, "meta")) {
                        if (!self.is_module) {
                            self.addError(.{ .start = span.start, .end = prop_span.end }, "'import.meta' is only allowed in module code");
                        }
                        return try self.ast.addNode(.{
                            .tag = .meta_property,
                            .span = .{ .start = span.start, .end = prop_span.end },
                            .data = .{ .none = 0 },
                        });
                    }

                    // import.source(...) / import.defer(...) — dynamic import 변형
                    // 인자가 있으면 call expression처럼 처리
                    if (self.current() == .l_paren) {
                        self.advance(); // skip (
                        const arg = try self.parseAssignmentExpression();
                        if (self.eat(.comma)) {
                            if (self.current() != .r_paren) {
                                _ = try self.parseAssignmentExpression();
                                _ = self.eat(.comma);
                            }
                        }
                        self.expect(.r_paren);
                        return try self.ast.addNode(.{
                            .tag = .import_expression,
                            .span = .{ .start = span.start, .end = self.currentSpan().start },
                            .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
                        });
                    }

                    // import.source/defer without () → 에러
                    if (std.mem.eql(u8, prop_text, "source") or std.mem.eql(u8, prop_text, "defer")) {
                        self.addError(.{ .start = span.start, .end = prop_span.end }, "import.source/defer requires arguments");
                    }
                    return try self.ast.addNode(.{
                        .tag = .meta_property,
                        .span = .{ .start = span.start, .end = prop_span.end },
                        .data = .{ .none = 0 },
                    });
                }
                // dynamic import: import("module") or import("module", options)
                self.expect(.l_paren);
                const arg = try self.parseAssignmentExpression();
                // 두 번째 인자 (import assertions/options) — 있으면 파싱하고 무시
                if (self.eat(.comma)) {
                    if (self.current() != .r_paren) {
                        _ = try self.parseAssignmentExpression();
                        _ = self.eat(.comma); // trailing comma
                    }
                }
                self.expect(.r_paren);
                return try self.ast.addNode(.{
                    .tag = .import_expression,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
                });
            },
            .no_substitution_template => {
                // 보간 없는 템플릿 리터럴: `text`
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .template_literal,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .template_head => {
                // 보간 있는 템플릿 리터럴: `text${expr}...`
                return self.parseTemplateLiteral();
            },
            .regexp_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .regexp_literal,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .l_bracket => {
                // 배열 리터럴 — 내부에서 `in` 연산자 항상 허용
                const arr_saved = self.enterAllowInContext(true);
                const arr = try self.parseArrayExpression();
                self.restoreContext(arr_saved);
                return arr;
            },
            .l_curly => {
                // 객체 리터럴 — 내부에서 `in` 연산자 항상 허용
                const obj_saved = self.enterAllowInContext(true);
                const obj = try self.parseObjectExpression();
                self.restoreContext(obj_saved);
                return obj;
            },
            .kw_async => {
                // async function expression 또는 async arrow
                const peek = self.peekNext();
                if (peek.kind == .kw_function and !peek.has_newline_before) {
                    // async function expression
                    self.advance(); // skip 'async'
                    return self.parseFunctionExpressionWithFlags(ast_mod.FunctionFlags.is_async);
                }
                // async를 일반 식별자로 취급 (async arrow는 parseAssignmentExpression에서 처리)
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            else => {
                // contextual keyword, strict mode reserved, TS keyword는
                // expression에서 식별자로 사용 가능 (reserved keyword만 불가)
                // 단, yield/await는 generator/async 내부에서, strict mode reserved는 strict에서 불가
                // await/yield는 조건부 예약어 — parseUnaryExpression에서 이미 처리했으므로
                // 여기에 도달하면 식별자로 사용 가능한 컨텍스트
                if (self.current().isKeyword() and
                    (!self.current().isReservedKeyword() or self.current() == .kw_await or self.current() == .kw_yield))
                {
                    if (self.ctx.is_strict_mode and self.current().isStrictModeReserved()) {
                        self.addError(span, "reserved word in strict mode cannot be used as identifier");
                    } else {
                        self.checkYieldAwaitUse(span, "identifier");
                    }
                    self.advance();
                    return try self.ast.addNode(.{
                        .tag = .identifier_reference,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                }
                // 에러 복구: 알 수 없는 토큰 → 에러 노드 생성 후 건너뜀
                self.addError(span, "expression expected");
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .invalid,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
        }
    }

    /// 보간이 있는 템플릿 리터럴을 파싱한다: `head${expr}middle${expr}tail`
    fn parseTemplateLiteral(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const scratch_top = self.saveScratch();

        // template_head: `text${
        try self.scratch.append(try self.ast.addNode(.{
            .tag = .template_element,
            .span = self.currentSpan(),
            .data = .{ .none = 0 },
        }));
        self.advance(); // skip template_head

        while (true) {
            // expression inside ${} — `in` 연산자 항상 허용 (ECMAScript: TemplateMiddleList[+In])
            const tmpl_saved = self.enterAllowInContext(true);
            const expr = try self.parseExpression();
            self.restoreContext(tmpl_saved);
            try self.scratch.append(expr);

            // template_middle: }text${ 또는 template_tail: }text`
            if (self.current() == .template_middle) {
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = self.currentSpan(),
                    .data = .{ .none = 0 },
                }));
                self.advance();
            } else if (self.current() == .template_tail) {
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .template_element,
                    .span = self.currentSpan(),
                    .data = .{ .none = 0 },
                }));
                self.advance();
                break;
            } else {
                // 에러 복구: 닫히지 않은 템플릿
                self.addError(self.currentSpan(), "expected template continuation");
                break;
            }
        }

        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .template_literal,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = list },
        });
    }

    fn parseArrayExpression(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        var elements = std.ArrayList(NodeIndex).init(self.allocator);
        defer elements.deinit();

        while (self.current() != .r_bracket and self.current() != .eof) {
            if (self.current() == .comma) {
                // elision (빈 슬롯)
                const hole_span = self.currentSpan();
                try elements.append(try self.ast.addNode(.{
                    .tag = .elision,
                    .span = hole_span,
                    .data = .{ .none = 0 },
                }));
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

    fn parseObjectExpression(self: *Parser) ParseError2!NodeIndex {
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

    fn parseObjectProperty(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // spread: ...expr
        if (self.current() == .dot3) {
            self.advance();
            const expr = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
            });
        }

        // get/set 메서드 shorthand: { get prop() {}, set prop(v) {} }
        if (self.current() == .kw_get or self.current() == .kw_set) {
            const peek = self.peekNextKind();
            if (peek != .colon and peek != .l_paren and peek != .comma and peek != .r_curly) {
                const method_flags: u16 = if (self.current() == .kw_get) 0x02 else 0x04;
                self.advance(); // skip get/set
                const key = try self.parsePropertyKey();
                return self.parseObjectMethodBody(start, key, method_flags);
            }
        }

        // async 메서드 shorthand: { async foo() {} }
        if (self.current() == .kw_async) {
            const peek = self.peekNext();
            if (peek.kind != .colon and peek.kind != .comma and
                peek.kind != .r_curly and !peek.has_newline_before)
            {
                var method_flags: u16 = 0x08; // async
                self.advance(); // skip 'async'
                // async generator: { async *foo() {} }
                if (self.eat(.star)) method_flags |= 0x10;
                const key = try self.parsePropertyKey();
                return self.parseObjectMethodBody(start, key, method_flags);
            }
        }

        // generator 메서드: { *foo() {} }
        if (self.current() == .star) {
            self.advance(); // skip '*'
            const key = try self.parsePropertyKey();
            return self.parseObjectMethodBody(start, key, 0x10); // generator
        }

        // 키: identifier, string, number, 또는 computed [expr]
        const key = try self.parsePropertyKey();

        // 메서드 shorthand: { foo() {} }
        if (self.current() == .l_paren) {
            return self.parseObjectMethodBody(start, key, 0);
        }

        // key: value
        var value = NodeIndex.none;
        if (self.eat(.colon)) {
            value = try self.parseAssignmentExpression();
        } else if (self.eat(.eq)) {
            // shorthand with default: { x = 1 }  (destructuring default)
            value = try self.parseAssignmentExpression();
        } else {
            // shorthand: { x } — key가 identifier shorthand로 사용 가능한지 검증
            if (!key.isNone()) {
                const key_node = self.ast.getNode(key);
                if (key_node.tag == .identifier_reference) {
                    const key_text = self.ast.source[key_node.span.start..key_node.span.end];
                    if (token_mod.keywords.get(key_text)) |kw| {
                        if (kw.isReservedKeyword() or kw.isLiteralKeyword()) {
                            // reserved word (true, false, null, if, for 등)
                            self.addError(key_node.span, "reserved word cannot be used as shorthand property");
                        } else if (self.ctx.is_strict_mode and kw.isStrictModeReserved()) {
                            // strict mode reserved (yield, let, static, implements 등)
                            self.addError(key_node.span, "reserved word in strict mode cannot be used as shorthand property");
                        } else if (kw == .kw_yield and self.ctx.in_generator) {
                            self.addError(key_node.span, "'yield' cannot be used as shorthand property in generator");
                        } else if (kw == .kw_await and (self.ctx.in_async or self.is_module)) {
                            self.addError(key_node.span, "'await' cannot be used as shorthand property in async/module");
                        }
                    }
                }
            }
        }

        return try self.ast.addNode(.{
            .tag = .object_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
        });
    }

    /// 객체 리터럴 메서드의 파라미터와 본문을 파싱한다.
    /// flags: 0x02=getter, 0x04=setter, 0x08=async, 0x10=generator
    fn parseObjectMethodBody(self: *Parser, start: u32, key: NodeIndex, flags: u16) ParseError2!NodeIndex {
        self.expect(.l_paren);
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

        // TS 리턴 타입
        _ = try self.tryParseReturnType();

        // object method도 함수이므로 컨텍스트 설정 (return/break/continue 검증)
        const saved_ctx = self.enterFunctionContext((flags & 0x08) != 0, (flags & 0x10) != 0);
        // ECMAScript 12.3.7: 객체 리터럴 메서드에서도 super.prop 허용
        self.ctx.allow_super_property = true;
        self.ctx.has_simple_params = self.checkSimpleParams(scratch_top);
        self.checkDuplicateParams(scratch_top);
        const body = try self.parseFunctionBody();
        self.restoreContext(saved_ctx);

        const param_list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

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

    /// 바인딩 패턴을 파싱한다: identifier, [destructuring], {destructuring}
    fn parseBindingPattern(self: *Parser) ParseError2!NodeIndex {
        // TS parameter property: public x, private x, protected x, readonly x
        // flags 비트: 0x01=public, 0x02=private, 0x04=protected, 0x08=readonly
        if (self.current() == .kw_public or self.current() == .kw_private or
            self.current() == .kw_protected or self.current() == .kw_readonly)
        {
            const modifier_span = self.currentSpan();
            const next = self.peekNextKind();
            // modifier 뒤에 식별자가 오면 parameter property
            if (next == .identifier or next == .l_bracket or next == .l_curly or
                next == .kw_readonly) // public readonly x
            {
                var modifier_flags: u16 = switch (self.current()) {
                    .kw_public => 0x01,
                    .kw_private => 0x02,
                    .kw_protected => 0x04,
                    .kw_readonly => 0x08,
                    else => 0,
                };
                self.advance(); // skip first modifier

                // 두 번째 modifier: public readonly x
                if (self.current() == .kw_readonly) {
                    modifier_flags |= 0x08;
                    self.advance();
                }

                const inner = try self.parseBindingPattern();
                return try self.ast.addNode(.{
                    .tag = .formal_parameter,
                    .span = .{ .start = modifier_span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = inner, .flags = modifier_flags } },
                });
            }
        }

        // rest parameter: ...pattern
        if (self.current() == .dot3) {
            const rest_start = self.currentSpan().start;
            self.advance(); // skip '...'
            const pattern = try self.parseBindingPattern();
            self.checkBindingRestInit(pattern);
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = rest_start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = pattern, .flags = 0 } },
            });
        }

        switch (self.current()) {
            .identifier => {
                const span = self.currentSpan();
                self.checkStrictBinding(span);
                self.advance();
                const node = try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
                // TS: optional (?) + type annotation
                _ = self.eat(.question); // optional parameter
                _ = try self.tryParseTypeAnnotation();
                // default value: pattern = expr
                return self.tryWrapDefaultValue(node);
            },
            .l_bracket => {
                const pat = try self.parseArrayPattern();
                _ = self.eat(.question);
                _ = try self.tryParseTypeAnnotation();
                return self.tryWrapDefaultValue(pat);
            },
            .l_curly => {
                const pat = try self.parseObjectPattern();
                _ = self.eat(.question);
                _ = try self.tryParseTypeAnnotation();
                return self.tryWrapDefaultValue(pat);
            },
            .escaped_keyword => {
                // 이스케이프된 예약어는 식별자로 사용할 수 없음 (ECMAScript 12.1.1)
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier");
                const span = self.currentSpan();
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            else => {
                // contextual 키워드는 바인딩 이름으로 사용 가능 (let, yield, async 등)
                // 단, reserved keyword / yield in generator / await in async 는 불가
                if (self.current().isKeyword()) {
                    self.checkKeywordBinding();
                    const span = self.currentSpan();
                    self.advance();
                    const node2 = try self.ast.addNode(.{
                        .tag = .binding_identifier,
                        .span = span,
                        .data = .{ .string_ref = span },
                    });
                    return self.tryWrapDefaultValue(node2);
                }
                self.addError(self.currentSpan(), "binding pattern expected");
                return NodeIndex.none;
            },
        }
    }

    /// 하위 호환: 식별자만 필요한 곳에서 호출
    fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
        return self.parseBindingPattern();
    }

    /// `= expr` 이 있으면 assignment_pattern으로 감싼다. 없으면 원본 반환.
    /// 기본값 표현식에서는 `in` 연산자가 항상 허용된다 (ECMAScript: Initializer[+In]).
    fn tryWrapDefaultValue(self: *Parser, node: NodeIndex) ParseError2!NodeIndex {
        if (self.eat(.eq)) {
            const def_saved = self.enterAllowInContext(true);
            const default_val = try self.parseAssignmentExpression();
            self.restoreContext(def_saved);
            return try self.ast.addNode(.{
                .tag = .assignment_pattern,
                .span = .{ .start = self.ast.getNode(node).span.start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = node, .right = default_val, .flags = 0 } },
            });
        }
        return node;
    }

    /// 바인딩 이름만 파싱한다 (identifier, [array], {object}).
    /// `?`, 타입 어노테이션, default value `=`를 소비하지 않는다.
    /// variable declarator에서 사용 — `=`는 initializer이므로 여기서 소비하면 안 됨.
    fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
        switch (self.current()) {
            .identifier => {
                const span = self.currentSpan();
                self.checkStrictBinding(span);
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .l_bracket => return self.parseArrayPattern(),
            .l_curly => return self.parseObjectPattern(),
            .escaped_keyword => {
                self.addError(self.currentSpan(), "escaped reserved word cannot be used as identifier");
                const span = self.currentSpan();
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .binding_identifier,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            else => {
                if (self.current().isKeyword()) {
                    self.checkKeywordBinding();
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

    /// 단순 식별자 이름만 파싱한다 (타입 어노테이션/기본값 없이).
    /// type alias, interface, enum 등 선언 이름에 사용.
    fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .identifier or self.current() == .escaped_keyword or self.current().isKeyword()) {
            // 예약어 체크 (바인딩 위치에서)
            if (self.current() == .escaped_keyword) {
                self.addError(span, "escaped reserved word cannot be used as identifier");
            } else {
                self.checkKeywordBinding();
            }
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

    fn parseArrayPattern(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        const scratch_top = self.saveScratch();
        while (self.current() != .r_bracket and self.current() != .eof) {
            if (self.current() == .comma) {
                // elision (빈 슬롯) — placeholder 노드 추가
                const hole_span = self.currentSpan();
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .elision,
                    .span = hole_span,
                    .data = .{ .none = 0 },
                }));
                self.advance();
                continue;
            }
            if (self.current() == .dot3) {
                // rest element: ...pattern
                const rest_start = self.currentSpan().start;
                self.advance(); // skip ...
                const rest_arg = try self.parseBindingPattern();
                self.checkBindingRestInit(rest_arg);
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
                });
                try self.scratch.append(rest);
                break; // rest는 항상 마지막
            }
            const elem_raw = try self.parseBindingName();
            // default value: pattern = expr (배열/객체 패턴 뒤의 = default)
            var elem = try self.tryWrapDefaultValue(elem_raw);
            // TS: optional (?) + type annotation — 배열 패턴 요소에도 가능
            _ = self.eat(.question);
            _ = try self.tryParseTypeAnnotation();
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

    fn parseObjectPattern(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            if (self.current() == .dot3) {
                // rest element: ...pattern
                const rest_start = self.currentSpan().start;
                self.advance(); // skip ...
                const rest_arg = try self.parseBindingPattern();
                self.checkBindingRestInit(rest_arg);
                const rest = try self.ast.addNode(.{
                    .tag = .rest_element,
                    .span = .{ .start = rest_start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = rest_arg, .flags = 0 } },
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

    fn parseBindingProperty(self: *Parser) ParseError2!NodeIndex {
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
                const value = try self.tryWrapDefaultValue(key);
                return try self.ast.addNode(.{
                    .tag = .binding_property,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
                });
            }
        }

        // key: pattern = default
        const key = try self.parsePropertyKey();
        self.expect(.colon);
        const value_raw = try self.parseBindingPattern();
        // { x: pattern = defaultValue } 형태
        const value = try self.tryWrapDefaultValue(value_raw);

        return try self.ast.addNode(.{
            .tag = .binding_property,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value, .flags = 0 } },
        });
    }

    fn parseIdentifierName(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .identifier or self.current() == .escaped_keyword or self.current().isKeyword()) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .identifier_reference,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        if (self.current() == .private_identifier) {
            self.advance();
            return try self.ast.addNode(.{
                .tag = .private_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "identifier expected");
        self.advance();
        return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
    }

    /// 객체 프로퍼티 키를 파싱한다.
    /// 허용: identifier, string literal, numeric literal, computed [expr].
    /// spread (...expr) 또는 assignment expression을 파싱. ...가 있으면 spread_element로 감싼다.
    /// 인자 리스트를 파싱한다: (arg1, arg2, ...) → NodeList
    /// 여는 괄호 `(`는 이미 소비된 상태에서 호출.
    /// 닫는 괄호 `)`까지 소비한다.
    fn parseArgumentList(self: *Parser) ParseError2!NodeList {
        const scratch_top = self.saveScratch();
        while (self.current() != .r_paren and self.current() != .eof) {
            const arg = try self.parseSpreadOrAssignment();
            try self.scratch.append(arg);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_paren);
        const list = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        return list;
    }

    /// 함수 인자 하나를 파싱한다. `in` 연산자 허용 (ECMAScript: Arguments[+In]).
    fn parseSpreadOrAssignment(self: *Parser) ParseError2!NodeIndex {
        const arg_saved = self.enterAllowInContext(true);
        defer self.restoreContext(arg_saved);
        if (self.current() == .dot3) {
            const start = self.currentSpan().start;
            self.advance(); // skip ...
            const arg = try self.parseAssignmentExpression();
            return try self.ast.addNode(.{
                .tag = .spread_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .unary = .{ .operand = arg, .flags = 0 } },
            });
        }
        return self.parseAssignmentExpression();
    }

    fn parsePropertyKey(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        switch (self.current()) {
            .identifier, .escaped_keyword => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .identifier_reference,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            .private_identifier => {
                // #private 필드/메서드
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .private_identifier,
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
                    .data = .{ .none = 0 },
                });
            },
            .l_bracket => {
                // computed property: [expr] — `in` 연산자 허용 (ECMAScript: ComputedPropertyName[+In])
                self.advance();
                const cpk_saved = self.enterAllowInContext(true);
                const expr = try self.parseAssignmentExpression();
                self.restoreContext(cpk_saved);
                self.expect(.r_bracket);
                return try self.ast.addNode(.{
                    .tag = .computed_property_key,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
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
                return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
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

    // ================================================================
    // JSX 파싱
    // ================================================================

    /// <Tag ...>children</Tag> 또는 <Tag ... /> 또는 <>...</>
    fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.scanner.nextInsideJSXElement(); // '<' 이후 JSX 모드

        // Fragment: <>
        if (self.current() == .r_angle) {
            self.scanner.nextJSXChild(); // '>' 이후 children 모드
            return self.parseJSXFragment(start);
        }

        // Opening tag: <TagName
        const tag_name = try self.parseJSXTagName();

        // Attributes
        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .slash and self.current() != .eof) {
            const attr = try self.parseJSXAttribute();
            try self.scratch.append(attr);
        }
        const attrs = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        // Self-closing: />
        if (self.current() == .slash) {
            self.scanner.nextInsideJSXElement(); // skip /
            // expect >
            self.scanner.next(); // back to normal mode after >

            const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
            _ = try self.ast.addExtra(attrs.start);
            _ = try self.ast.addExtra(attrs.len);

            return try self.ast.addNode(.{
                .tag = .jsx_element,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .extra = extra_start },
            });
        }

        // > children </tag>
        self.scanner.nextJSXChild(); // '>' 이후 children 모드

        // Children
        const children_top = self.saveScratch();
        while (self.current() != .eof) {
            if (self.current() == .l_angle) {
                // 다음 토큰이 / 이면 닫는 태그 (JSX 모드로 peek)
                if (self.peekNextKindJSX() == .slash) break;
                // 중첩 JSX element
                const child = try self.parseJSXElement();
                try self.scratch.append(child);
            } else if (self.current() == .l_curly) {
                // JSX expression: {expr}
                self.advance(); // skip {
                const expr = try self.parseExpression();
                self.expect(.r_curly);
                const container = try self.ast.addNode(.{
                    .tag = .jsx_expression_container,
                    .span = .{ .start = 0, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
                try self.scratch.append(container);
                self.scanner.nextJSXChild(); // '{expr}' 이후 다시 children 모드
            } else if (self.current() == .jsx_text) {
                const text_span = self.currentSpan();
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .jsx_text,
                    .span = text_span,
                    .data = .{ .string_ref = text_span },
                }));
                self.scanner.nextJSXChild();
            } else {
                break;
            }
        }
        const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
        self.restoreScratch(children_top);

        // Closing tag: </TagName>
        self.scanner.nextInsideJSXElement(); // skip <
        self.scanner.nextInsideJSXElement(); // skip /
        // skip tag name
        if (self.current() == .jsx_identifier or self.current() == .identifier) {
            self.scanner.nextInsideJSXElement();
        }
        // expect >
        self.scanner.next(); // back to normal mode

        const extra_start = try self.ast.addExtra(@intFromEnum(tag_name));
        _ = try self.ast.addExtra(attrs.start);
        _ = try self.ast.addExtra(attrs.len);
        _ = try self.ast.addExtra(children.start);
        _ = try self.ast.addExtra(children.len);

        return try self.ast.addNode(.{
            .tag = .jsx_element,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseJSXFragment(self: *Parser, start: u32) ParseError2!NodeIndex {
        // Children
        const children_top = self.saveScratch();
        while (self.current() != .eof) {
            if (self.current() == .l_angle) {
                // JSX 모드로 peek (normal 모드에서는 /가 regex로 해석될 수 있음)
                if (self.peekNextKindJSX() == .slash) break;
                const child = try self.parseJSXElement();
                try self.scratch.append(child);
            } else if (self.current() == .l_curly) {
                self.advance();
                const expr = try self.parseExpression();
                self.expect(.r_curly);
                const container = try self.ast.addNode(.{
                    .tag = .jsx_expression_container,
                    .span = .{ .start = 0, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
                try self.scratch.append(container);
                self.scanner.nextJSXChild();
            } else if (self.current() == .jsx_text) {
                const text_span = self.currentSpan();
                try self.scratch.append(try self.ast.addNode(.{
                    .tag = .jsx_text,
                    .span = text_span,
                    .data = .{ .string_ref = text_span },
                }));
                self.scanner.nextJSXChild();
            } else {
                break;
            }
        }
        const children = try self.ast.addNodeList(self.scratch.items[children_top..]);
        self.restoreScratch(children_top);

        // </>
        self.scanner.nextInsideJSXElement(); // <
        self.scanner.nextInsideJSXElement(); // /
        self.scanner.next(); // >

        return try self.ast.addNode(.{
            .tag = .jsx_fragment,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = children },
        });
    }

    fn parseJSXTagName(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();
        if (self.current() == .jsx_identifier or self.current() == .identifier) {
            self.scanner.nextInsideJSXElement();
            return try self.ast.addNode(.{
                .tag = .jsx_identifier,
                .span = span,
                .data = .{ .string_ref = span },
            });
        }
        self.addError(span, "JSX tag name expected");
        return NodeIndex.none;
    }

    fn parseJSXAttribute(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;

        // spread attribute: {...expr}
        if (self.current() == .l_curly) {
            self.advance();
            if (self.current() == .dot3) {
                self.advance();
                const expr = try self.parseAssignmentExpression();
                self.expect(.r_curly);
                return try self.ast.addNode(.{
                    .tag = .jsx_spread_attribute,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
                });
            }
            self.addError(self.currentSpan(), "spread expected");
            return NodeIndex.none;
        }

        // name="value" or name={expr}
        const name_span = self.currentSpan();
        self.scanner.nextInsideJSXElement(); // skip attribute name

        const name = try self.ast.addNode(.{
            .tag = .jsx_identifier,
            .span = name_span,
            .data = .{ .string_ref = name_span },
        });

        var value = NodeIndex.none;
        if (self.current() == .eq) {
            self.scanner.nextInsideJSXElement(); // skip =
            if (self.current() == .string_literal) {
                const val_span = self.currentSpan();
                self.scanner.nextInsideJSXElement();
                value = try self.ast.addNode(.{
                    .tag = .string_literal,
                    .span = val_span,
                    .data = .{ .string_ref = val_span },
                });
            } else if (self.current() == .l_curly) {
                self.advance();
                value = try self.parseAssignmentExpression();
                self.expect(.r_curly);
            }
        }

        return try self.ast.addNode(.{
            .tag = .jsx_attribute,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = value, .flags = 0 } },
        });
    }

    // ================================================================
    // TypeScript Declarations
    // ================================================================

    /// type Foo = Type;
    fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'type'

        const name = try self.parseSimpleIdentifier();

        // 제네릭 파라미터: type Foo<T> = ...
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        self.expect(.eq);
        const ty = try self.parseType();
        _ = self.eat(.semicolon);

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_params));
        _ = try self.ast.addExtra(@intFromEnum(ty));

        return try self.ast.addNode(.{
            .tag = .ts_type_alias_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// interface Foo { ... }
    fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'interface'

        const name = try self.parseSimpleIdentifier();

        // 제네릭 파라미터
        var type_params = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_params = try self.parseTsTypeParameterDeclaration();
        }

        // extends (콤마 구분 리스트: interface Foo extends Bar, Baz)
        var extends_node = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            // 첫 번째 타입은 항상 파싱
            extends_node = try self.parseType();
            // 추가 extends 타입들은 무시 (BACKLOG: 리스트로 변환)
            while (self.eat(.comma)) {
                _ = try self.parseType();
            }
        }

        // interface body
        const body = try self.parseObjectType();

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(type_params));
        _ = try self.ast.addExtra(@intFromEnum(extends_node));
        _ = try self.ast.addExtra(@intFromEnum(body));

        return try self.ast.addNode(.{
            .tag = .ts_interface_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    /// const enum Foo { A, B, C }
    /// const enum은 일반 enum과 동일하게 파싱하되, flags=1로 표시.
    fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'const'
        return self.parseTsEnumDeclarationWithFlags(1);
    }

    /// enum Foo { A, B, C }
    fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
        return self.parseTsEnumDeclarationWithFlags(0);
    }

    /// enum 파싱. flags: 0=일반 enum, 1=const enum.
    /// extra = [name, members_start, members_len, flags]
    fn parseTsEnumDeclarationWithFlags(self: *Parser, flags: u32) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'enum'

        const name = try self.parseSimpleIdentifier();
        self.expect(.l_curly);

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const member = try self.parseTsEnumMember();
            try self.scratch.append(member);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        const extra_start = try self.ast.addExtras(&.{
            @intFromEnum(name), members.start, members.len, flags,
        });

        return try self.ast.addNode(.{
            .tag = .ts_enum_declaration,
            .span = .{ .start = start, .end = end },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseTsEnumMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name = try self.parsePropertyKey();

        var init_val = NodeIndex.none;
        if (self.eat(.eq)) {
            init_val = try self.parseAssignmentExpression();
        }

        return try self.ast.addNode(.{
            .tag = .ts_enum_member,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = init_val, .flags = 0 } },
        });
    }

    /// namespace Foo { ... } / module "name" { ... }
    fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip 'namespace' or 'module'
        return self.parseTsModuleBody(start);
    }

    /// namespace body (재귀: A.B.C 중첩 처리). keyword는 이미 소비된 상태.
    fn parseTsModuleBody(self: *Parser, start: u32) ParseError2!NodeIndex {
        const name = try self.parseSimpleIdentifier();

        // 중첩: namespace A.B.C { }
        if (self.eat(.dot)) {
            const inner = try self.parseTsModuleBody(start);
            return try self.ast.addNode(.{
                .tag = .ts_module_declaration,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = name, .right = inner, .flags = 0 } },
            });
        }

        const body = try self.parseBlockStatement();

        return try self.ast.addNode(.{
            .tag = .ts_module_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = name, .right = body, .flags = 0 } },
        });
    }

    /// declare var/let/const/function/class/...
    fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'declare'
        // declare 뒤의 선언은 ambient context (const 이니셜라이저 불필요 등)
        const saved = self.ctx;
        self.ctx.in_ambient = true;
        const result = try self.parseStatement();
        self.ctx = saved;
        return result;
    }

    /// abstract class Foo { }
    fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
        self.advance(); // skip 'abstract'
        return self.parseClassDeclaration();
    }

    /// @decorator 파싱 후 class/export 문을 파싱
    fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
        // 데코레이터 수집
        const scratch_top = self.saveScratch();
        while (self.current() == .at) {
            const dec = try self.parseDecorator();
            try self.scratch.append(dec);
        }
        const decorators = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        // 데코레이터 뒤에 올 수 있는 것: class, export, abstract
        return switch (self.current()) {
            .kw_class => self.parseClassWithDecorators(.class_declaration, decorators),
            .kw_export => self.parseExportDeclaration(),
            .kw_abstract => self.parseTsAbstractClass(),
            else => {
                self.addError(self.currentSpan(), "class or export expected after decorator");
                return self.parseExpressionStatement();
            },
        };
    }

    /// @expr — 단일 데코레이터 파싱
    fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip @
        const expr = try self.parseCallExpression();

        return try self.ast.addNode(.{
            .tag = .decorator,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = expr, .flags = 0 } },
        });
    }

    /// <T, U extends V = W>
    fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip <

        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .eof) {
            const param = try self.parseTsTypeParameter();
            try self.scratch.append(param);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_angle);

        const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter_declaration,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = params },
        });
    }

    fn parseTsTypeParameter(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name = try self.parseSimpleIdentifier();

        // T extends U
        var constraint = NodeIndex.none;
        if (self.eat(.kw_extends)) {
            constraint = try self.parseType();
        }

        // T = DefaultType
        var default_type = NodeIndex.none;
        if (self.eat(.eq)) {
            default_type = try self.parseType();
        }

        const extra_start = try self.ast.addExtra(@intFromEnum(name));
        _ = try self.ast.addExtra(@intFromEnum(constraint));
        _ = try self.ast.addExtra(@intFromEnum(default_type));

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    // ================================================================
    // TypeScript Type 파싱
    // ================================================================

    /// `: Type` 어노테이션이 있으면 파싱하고 노드 반환. 없으면 none.
    fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
        if (self.current() != .colon) return NodeIndex.none;
        // 타입 어노테이션이 아닌 colon인 경우 구분 필요:
        // object literal `{ key: value }`, ternary `? : `, switch `case:` 등
        // 여기서는 binding pattern/variable declarator 컨텍스트에서만 호출되므로 안전
        self.advance(); // skip ':'
        return self.parseType();
    }

    /// 리턴 타입 어노테이션 (`: Type`). 함수 선언에서 사용.
    fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
        if (self.current() != .colon) return NodeIndex.none;
        self.advance();
        return self.parseType();
    }

    /// TS 타입을 파싱한다. 유니온/인터섹션을 포함.
    fn parseType(self: *Parser) ParseError2!NodeIndex {
        var left = try self.parseIntersectionType();

        // 유니온: A | B | C
        while (self.current() == .pipe) {
            const start = self.ast.getNode(left).span.start;
            self.advance(); // skip |
            const right = try self.parseIntersectionType();
            left = try self.ast.addNode(.{
                .tag = .ts_union_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
            });
        }

        return left;
    }

    fn parseIntersectionType(self: *Parser) ParseError2!NodeIndex {
        var left = try self.parsePostfixType();

        // 인터섹션: A & B & C
        while (self.current() == .amp) {
            const start = self.ast.getNode(left).span.start;
            self.advance(); // skip &
            const right = try self.parsePostfixType();
            left = try self.ast.addNode(.{
                .tag = .ts_intersection_type,
                .span = .{ .start = start, .end = self.currentSpan().start },
                .data = .{ .binary = .{ .left = left, .right = right, .flags = 0 } },
            });
        }

        return left;
    }

    fn parsePostfixType(self: *Parser) ParseError2!NodeIndex {
        var base = try self.parsePrimaryType();

        while (self.current() == .l_bracket) {
            const start = self.ast.getNode(base).span.start;
            if (self.peekNextKind() == .r_bracket) {
                // 배열 타입: T[]
                self.advance(); // [
                self.advance(); // ]
                base = try self.ast.addNode(.{
                    .tag = .ts_array_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = base, .flags = 0 } },
                });
            } else {
                // 인덱스 접근 타입: T[K]
                self.advance(); // [
                const index_type = try self.parseType();
                self.expect(.r_bracket);
                base = try self.ast.addNode(.{
                    .tag = .ts_indexed_access_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = base, .right = index_type, .flags = 0 } },
                });
            }
        }

        return base;
    }

    fn parsePrimaryType(self: *Parser) ParseError2!NodeIndex {
        const span = self.currentSpan();

        // TS 키워드 타입
        if (self.current().isTypeScriptKeyword()) {
            const tag: Tag = switch (self.current()) {
                .kw_any => .ts_any_keyword,
                .kw_string => .ts_string_keyword,
                .kw_number => .ts_number_keyword,
                .kw_boolean => .ts_boolean_keyword,
                .kw_bigint => .ts_bigint_keyword,
                .kw_symbol => .ts_symbol_keyword,
                .kw_object => .ts_object_keyword,
                .kw_never => .ts_never_keyword,
                .kw_unknown => .ts_unknown_keyword,
                .kw_undefined => .ts_undefined_keyword,
                else => .ts_type_reference, // 다른 TS 키워드는 타입 참조로
            };
            if (tag != .ts_type_reference) {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = tag,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            }
        }

        switch (self.current()) {
            // void
            .kw_void => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_void_keyword,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // null
            .kw_null => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_null_keyword,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // this
            .kw_this => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_this_type,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            // 리터럴 타입 (true, false, 숫자, 문자열)
            .kw_true, .kw_false => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_literal_type,
                    .span = span,
                    .data = .{ .none = 0 },
                });
            },
            .decimal, .float, .hex, .string_literal => {
                self.advance();
                return try self.ast.addNode(.{
                    .tag = .ts_literal_type,
                    .span = span,
                    .data = .{ .string_ref = span },
                });
            },
            // 타입 참조: Foo, Foo.Bar, Foo<T>
            .identifier => return self.parseTypeReference(),
            // 괄호 타입: (Type) 또는 함수 타입: (a: T) => R
            .l_paren => return self.parseParenOrFunctionType(),
            // 객체 타입 리터럴: { x: number, y: string }
            .l_curly => return self.parseObjectType(),
            // 튜플 타입: [T, U]
            .l_bracket => return self.parseTupleType(),
            // typeof T
            .kw_typeof => {
                self.advance();
                const operand = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_type_query,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            },
            // keyof T
            .kw_keyof => {
                self.advance();
                const operand = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_type_operator,
                    .span = .{ .start = span.start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = operand, .flags = 0 } },
                });
            },
            else => {
                // 다른 TS 키워드가 타입 위치에 온 경우 타입 참조로 처리
                if (self.current().isKeyword()) {
                    return self.parseTypeReference();
                }
                self.addError(span, "type expected");
                self.advance();
                return try self.ast.addNode(.{ .tag = .invalid, .span = span, .data = .{ .none = 0 } });
            },
        }
    }

    fn parseTypeReference(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        const name_span = self.currentSpan();
        self.advance(); // type name

        // Foo.Bar 형태
        var name_end = name_span.end;
        while (self.eat(.dot)) {
            name_end = self.currentSpan().end;
            self.advance(); // Bar
        }

        // 제네릭: Foo<T, U>
        var type_args = NodeIndex.none;
        if (self.current() == .l_angle) {
            type_args = try self.parseTypeArguments();
        }

        const extra_start = try self.ast.addExtra(name_span.start);
        _ = try self.ast.addExtra(name_end);
        _ = try self.ast.addExtra(@intFromEnum(type_args));

        return try self.ast.addNode(.{
            .tag = .ts_type_reference,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = extra_start },
        });
    }

    fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip <

        const scratch_top = self.saveScratch();
        while (self.current() != .r_angle and self.current() != .eof) {
            const ty = try self.parseType();
            try self.scratch.append(ty);
            if (!self.eat(.comma)) break;
        }
        self.expect(.r_angle);

        const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_parameter_instantiation,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = types },
        });
    }

    fn parseParenOrFunctionType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip (

        // 빈 괄호 + => → 함수 타입 () => R
        if (self.current() == .r_paren) {
            self.advance();
            if (self.current() == .arrow) {
                self.advance();
                const return_type = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_function_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .unary = .{ .operand = return_type, .flags = 0 } },
                });
            }
            // 빈 괄호 — 에러 또는 void
            return try self.ast.addNode(.{ .tag = .ts_void_keyword, .span = .{ .start = start, .end = self.currentSpan().start }, .data = .{ .none = 0 } });
        }

        // 파라미터가 있는 경우 — 단순히 첫 번째 타입을 파싱하고 ) 뒤에 =>가 있으면 함수 타입
        const inner = try self.parseType();
        if (self.current() == .r_paren) {
            self.advance();
            if (self.current() == .arrow) {
                self.advance();
                const return_type = try self.parseType();
                return try self.ast.addNode(.{
                    .tag = .ts_function_type,
                    .span = .{ .start = start, .end = self.currentSpan().start },
                    .data = .{ .binary = .{ .left = inner, .right = return_type, .flags = 0 } },
                });
            }
        } else {
            self.expect(.r_paren);
        }

        // 괄호 타입: (Type)
        return try self.ast.addNode(.{
            .tag = .ts_parenthesized_type,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .unary = .{ .operand = inner, .flags = 0 } },
        });
    }

    fn parseObjectType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip {

        const scratch_top = self.saveScratch();
        while (self.current() != .r_curly and self.current() != .eof) {
            const member = try self.parseTypeMember();
            try self.scratch.append(member);
            // ; 또는 , 로 구분
            if (!self.eat(.semicolon) and !self.eat(.comma)) {
                if (self.current() != .r_curly) break;
            }
        }

        const end = self.currentSpan().end;
        self.expect(.r_curly);

        const members = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_type_literal,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = members },
        });
    }

    fn parseTypeMember(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        // 간단: key: Type 또는 key?: Type
        const key = try self.parsePropertyKey();
        _ = self.eat(.question); // optional
        self.expect(.colon);
        const value_type = try self.parseType();

        return try self.ast.addNode(.{
            .tag = .ts_property_signature,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .binary = .{ .left = key, .right = value_type, .flags = 0 } },
        });
    }

    fn parseTupleType(self: *Parser) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        self.advance(); // skip [

        const scratch_top = self.saveScratch();
        while (self.current() != .r_bracket and self.current() != .eof) {
            const ty = try self.parseType();
            try self.scratch.append(ty);
            if (!self.eat(.comma)) break;
        }

        const end = self.currentSpan().end;
        self.expect(.r_bracket);

        const types = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);

        return try self.ast.addNode(.{
            .tag = .ts_tuple_type,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = types },
        });
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
    var scanner = Scanner.init(std.testing.allocator, "function f(x) { if (x) { return 1; } else { return 2; } }");
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
        \\function f(x) {
        \\  switch (x) {
        \\    case 1: break;
        \\    case 2: return 2;
        \\    default: return 0;
        \\  }
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
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default" {
    var scanner = Scanner.init(std.testing.allocator, "import foo from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import named" {
    var scanner = Scanner.init(std.testing.allocator, "import { a, b as c } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import namespace" {
    var scanner = Scanner.init(std.testing.allocator, "import * as ns from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default + named" {
    var scanner = Scanner.init(std.testing.allocator, "import React, { useState } from 'react';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default" {
    var scanner = Scanner.init(std.testing.allocator, "export default 42;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named" {
    var scanner = Scanner.init(std.testing.allocator, "export { a, b as c };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export declaration" {
    var scanner = Scanner.init(std.testing.allocator, "export const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export all re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export * from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named re-export" {
    var scanner = Scanner.init(std.testing.allocator, "export { foo } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default function" {
    var scanner = Scanner.init(std.testing.allocator, "export default function foo() { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
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

test "Parser: class with private field and method" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Counter {
        \\  #count = 0;
        \\  #increment() { this.#count++; }
        \\  get value() { return this.#count; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: private field access" {
    var scanner = Scanner.init(std.testing.allocator, "this.#name;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (array)" {
    // 배열 대입 구조분해 — 현재 array_expression + assignment로 파싱됨
    // semantic analysis에서 assignment target으로 변환 예정
    var scanner = Scanner.init(std.testing.allocator, "[a, b] = [1, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (object)" {
    var scanner = Scanner.init(std.testing.allocator, "({ x, y } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import.meta" {
    var scanner = Scanner.init(std.testing.allocator, "const url = import.meta.url;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array elision [, , x]" {
    var scanner = Scanner.init(std.testing.allocator, "const [, , x] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript type tests
// ============================================================

test "Parser: TS variable with type annotation" {
    var scanner = Scanner.init(std.testing.allocator, "const x: number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS function with typed params and return" {
    var scanner = Scanner.init(std.testing.allocator, "function add(a: number, b: number): number { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS union type" {
    var scanner = Scanner.init(std.testing.allocator, "const x: string | number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS array type" {
    var scanner = Scanner.init(std.testing.allocator, "const arr: number[] = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type" {
    var scanner = Scanner.init(std.testing.allocator, "const arr: Array<string> = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS as expression" {
    var scanner = Scanner.init(std.testing.allocator, "const x = value as string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS non-null assertion" {
    var scanner = Scanner.init(std.testing.allocator, "const x = value!;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS object type literal" {
    var scanner = Scanner.init(std.testing.allocator, "const obj: { x: number; y: string } = { x: 1, y: 'a' };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS tuple type" {
    var scanner = Scanner.init(std.testing.allocator, "const t: [string, number] = ['a', 1];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS typeof and keyof" {
    var scanner = Scanner.init(std.testing.allocator, "const k: keyof typeof obj = 'x';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// TypeScript declaration tests
// ============================================================

test "Parser: TS type alias" {
    var scanner = Scanner.init(std.testing.allocator, "type StringOrNumber = string | number;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type alias" {
    var scanner = Scanner.init(std.testing.allocator, "type Result<T, E> = { ok: T } | { err: E };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface" {
    var scanner = Scanner.init(std.testing.allocator,
        \\interface User {
        \\  name: string;
        \\  age: number;
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface extends" {
    var scanner = Scanner.init(std.testing.allocator, "interface Admin extends User { role: string; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS enum" {
    var scanner = Scanner.init(std.testing.allocator,
        \\enum Color {
        \\  Red,
        \\  Green = 10,
        \\  Blue
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS namespace" {
    var scanner = Scanner.init(std.testing.allocator, "namespace Utils { const x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS declare" {
    var scanner = Scanner.init(std.testing.allocator, "declare const VERSION: string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS abstract class" {
    var scanner = Scanner.init(std.testing.allocator, "abstract class Shape { abstract area(): number; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type parameter with constraint and default" {
    var scanner = Scanner.init(std.testing.allocator, "type Foo<T extends string = 'hello'> = T;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS parameter property" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo { constructor(public x: number, private y: string) { } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class" {
    var scanner = Scanner.init(std.testing.allocator, "@Component class Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator with arguments" {
    var scanner = Scanner.init(std.testing.allocator, "@Injectable() class Service { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class member" {
    var scanner = Scanner.init(std.testing.allocator,
        \\class Foo {
        \\  @log
        \\  public greet(): void { }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class implements" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo implements Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: static readonly member" {
    var scanner = Scanner.init(std.testing.allocator, "class Foo { static readonly MAX = 100; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with generics" {
    var scanner = Scanner.init(std.testing.allocator, "class Box<T> { value: T; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// JSX tests
// ============================================================

test "Parser: JSX self-closing element" {
    var scanner = Scanner.init(std.testing.allocator, "const x = <br />;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX element with children" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <div>hello</div>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with attributes" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <div className="foo" id="bar" />;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with expression" {
    var scanner = Scanner.init(std.testing.allocator,
        \\const x = <span>{name}</span>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function call with division in args" {
    // arrow lookahead가 prev_token_kind를 복구하지 않으면
    // / 가 regex로 해석되어 실패하던 버그 테스트
    const source = "truncate(x / y)";
    var scanner = Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ================================================================
// 컨텍스트 검증 테스트 (D051)
// ================================================================

test "Parser: return outside function is error" {
    var scanner = Scanner.init(std.testing.allocator, "return 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'return' outside of function", parser.errors.items[0].message);
}

test "Parser: return inside function is valid" {
    var scanner = Scanner.init(std.testing.allocator, "function f() { return 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: return inside arrow function is valid" {
    var scanner = Scanner.init(std.testing.allocator, "const f = () => { return 1; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break outside loop/switch is error" {
    var scanner = Scanner.init(std.testing.allocator, "break;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: break inside loop is valid" {
    var scanner = Scanner.init(std.testing.allocator, "while (true) { break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break inside switch is valid" {
    var scanner = Scanner.init(std.testing.allocator, "function f(x) { switch (x) { case 1: break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: continue outside loop is error" {
    var scanner = Scanner.init(std.testing.allocator, "continue;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'continue' outside of loop", parser.errors.items[0].message);
}

test "Parser: continue inside for loop is valid" {
    var scanner = Scanner.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { continue; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break in nested function inside loop is error" {
    // 함수 경계에서 loop 컨텍스트가 리셋되므로, 내부 함수의 break는 에러
    var scanner = Scanner.init(std.testing.allocator, "while (true) { function f() { break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: with statement in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator,
        \\"use strict";
        \\with (obj) { x; }
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: with statement in non-strict mode is valid" {
    var scanner = Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: use strict in function body" {
    // 함수 내부 "use strict"가 strict mode를 설정하는지 확인
    var scanner = Scanner.init(std.testing.allocator,
        \\function f() {
        \\  "use strict";
        \\  with (obj) { x; }
        \\}
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

test "Parser: module mode is always strict" {
    var scanner = Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'with' is not allowed in strict mode", parser.errors.items[0].message);
}

// ================================================================
// 예약어 검증 테스트
// ================================================================

test "Parser: reserved word as variable name is error" {
    var scanner = Scanner.init(std.testing.allocator, "var var = 123;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator,
        \\"use strict";
        \\var implements = 1;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in non-strict is valid" {
    var scanner = Scanner.init(std.testing.allocator, "var implements = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: let as variable name is valid in non-strict" {
    var scanner = Scanner.init(std.testing.allocator, "var let = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

// ============================================================
// 검증 로직 유닛 테스트
// ============================================================

test "Parser: ++this is invalid assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "++this;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: delete identifier in strict mode is error" {
    var scanner = Scanner.init(std.testing.allocator, "\"use strict\"; delete x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: const without initializer is error" {
    var scanner = Scanner.init(std.testing.allocator, "const x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: for-of const without init is valid" {
    var scanner = Scanner.init(std.testing.allocator, "for (const x of [1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import/export only at module top-level" {
    // import in function body — error even in module
    var scanner = Scanner.init(std.testing.allocator, "function f() { import 'x'; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: function in loop body is error" {
    var scanner = Scanner.init(std.testing.allocator, "for (;;) function f() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: yield is identifier outside generator" {
    var scanner = Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is identifier in script mode" {
    var scanner = Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is reserved in module mode" {
    var scanner = Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: super outside method is error" {
    var scanner = Scanner.init(std.testing.allocator, "super.x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: new.target outside function is error" {
    var scanner = Scanner.init(std.testing.allocator, "new.target;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: object shorthand reserved word is error" {
    var scanner = Scanner.init(std.testing.allocator, "({true});");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional chaining is not assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "x?.y = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: parenthesized destructuring is not assignment target" {
    var scanner = Scanner.init(std.testing.allocator, "({}) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}
