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
const jsx = @import("jsx.zig");
const ts = @import("ts.zig");
pub const Diagnostic = @import("../diagnostic.zig").Diagnostic;

/// 재귀 함수용 명시적 에러 타입.
/// Zig는 재귀 함수에서 `!T` (inferred error set)를 사용할 수 없다.
/// 파서의 모든 에러는 메모리 할당 실패뿐이므로 Allocator.Error로 충분하다.
pub const ParseError2 = std.mem.Allocator.Error;

/// 괄호 매칭 정보. 여는 괄호를 만나면 push, 닫는 괄호를 만나면 pop.
/// 닫는 괄호 에러 시 "opened here" 위치를 보여주기 위해 사용.
const BracketInfo = struct {
    kind: Kind,
    span: Span,
};

/// 재귀 하강 파서.
/// Scanner에서 토큰을 하나씩 읽어 AST를 구축한다.
pub const Parser = struct {
    /// 렉서 (토큰 공급)
    scanner: *Scanner,

    /// AST 저장소
    ast: Ast,

    /// 수집된 에러 목록 (D039: 다중 에러)
    errors: std.ArrayList(Diagnostic),

    /// Unambiguous 모드에서 모듈 전용 에러를 지연 수집하는 버퍼.
    /// 파싱 완료 후 모듈로 확정되면 errors에 병합, 스크립트면 폐기.
    /// oxc의 deferred_module_errors와 동일한 역할.
    deferred_module_errors: std.ArrayList(Diagnostic),

    /// 재사용 가능한 임시 버퍼 (리스트 수집용). 매 사용 시 clearRetainingCapacity.
    scratch: std.ArrayList(NodeIndex),

    /// arrow 파라미터 중복 검사용 임시 이름 수집 버퍼.
    param_name_spans: std.ArrayList(Span),

    /// 괄호 매칭 스택 — 여는 괄호의 위치를 추적하여 닫힘 에러 시 "opened here" 표시.
    bracket_stack: std.ArrayList(BracketInfo),

    /// 메모리 할당자
    allocator: std.mem.Allocator,

    // ================================================================
    // 컨텍스트 플래그 (D051: 파서에서 구문 컨텍스트 추적)
    // ================================================================
    //
    // Context(u8)는 ECMAScript 문법 파라미터([+In], [+Yield] 등)만 포함한다.
    // 나머지 파서 상태는 개별 bool 필드로 관리한다.
    //
    // is_module은 파싱 시작 시 한 번 결정되고 변하지 않는 불변 설정이므로
    // Context에 포함하지 않고 별도 필드로 관리한다 (oxc/Babel/Hermes 방식).

    /// 파싱 컨텍스트 bitflags — ECMAScript 문법 파라미터만 포함.
    ctx: Context = Context.default,

    /// module 모드인지 (import/export 허용, 항상 strict).
    /// 파싱 시작 시 한 번 결정되는 불변 설정이므로 Context에 포함하지 않음.
    /// Unambiguous 모드에서는 낙관적으로 true로 시작하고, 파싱 후 확정.
    is_module: bool = false,

    /// Unambiguous 모드인지 (.ts/.tsx — 내용 기반 모듈 판별, oxc 방식).
    /// true이면 is_module=true로 낙관적 파싱하되, 모듈 전용 에러를 지연 수집.
    /// 파싱 완료 후 import/export 유무로 확정: 없으면 is_module=false + 에러 폐기.
    is_unambiguous: bool = false,

    /// import/export/import.meta가 발견되었는지. Unambiguous 모드에서 모듈 확정 기준.
    has_module_syntax: bool = false,

    /// namespace body 안인지. export/import를 허용하되 await를 키워드로 취급하지 않음.
    /// is_module과 분리: namespace는 export/import를 허용하지만 module code가 아님.
    in_namespace: bool = false,

    /// JSX 모드 (TSX). true이면 <는 JSX 엘리먼트 시작으로 우선 해석.
    /// false이면 <T>()=>{}가 제네릭 arrow로 해석.
    is_jsx: bool = false,

    /// TypeScript 모드 (.ts/.tsx/.mts). TS에서는 function overload, duplicate export 등이 합법.
    is_ts: bool = false,

    // ================================================================
    // 개별 파서 상태 플래그
    // ================================================================

    /// TS 타입 어노테이션 안인지 (렉서 동작 변경: `<`/`>`를 타입 구분자로)
    in_type: bool = false,
    /// 함수 파라미터 안인지
    in_parameters: bool = false,
    /// new.target 허용 여부
    allow_new_target: bool = false,
    /// constructor 안인지
    is_constructor: bool = false,
    /// strict mode 여부 (D054: "use strict" directive 또는 module mode)
    is_strict_mode: bool = false,
    /// 루프 안에 있는지 (continue 유효성 검증용)
    in_loop: bool = false,
    /// switch 안에 있는지 (break 유효성 검증용 — break는 loop OR switch에서 허용)
    in_switch: bool = false,
    /// 현재 파싱 중인 함수의 파라미터가 simple인지 (non-simple이면 "use strict" 금지)
    has_simple_params: bool = true,
    /// for 초기화절 안인지 (for-in/for-of 구분)
    for_loop_init: bool = false,
    /// class 본문 안인지
    in_class: bool = false,
    /// class field 초기값 안인지
    in_class_field: bool = false,
    /// extends 있는 class인지 (super() 허용 판단)
    has_super_class: bool = false,
    /// super() 호출 허용 여부 (constructor + extends)
    allow_super_call: bool = false,
    /// super.x / super[x] 허용 여부
    allow_super_property: bool = false,
    /// static initializer (static { }) 안인지 — arguments 사용 금지
    in_static_initializer: bool = false,
    /// object literal에서 CoverInitializedName (shorthand with default: { x = 1 }) 가 있었는지.
    /// cover grammar 변환(destructuring)에서 소비되지 않으면 에러.
    has_cover_init_name: bool = false,
    /// formal parameter 파싱 중인지 (yield/await expression 금지).
    in_formal_parameters: bool = false,
    /// if/with/labeled body에서 labelled function statement 금지 체크 중인지.
    /// IsLabelledFunction(Statement) is true → SyntaxError
    in_labelled_fn_check: bool = false,

    // ================================================================
    // Context packed struct 정의
    // ================================================================

    /// ECMAScript 문법 파라미터를 추적하는 bitflags.
    ///
    /// packed struct(u8)에는 문법 파라미터(allow_in, in_generator 등)만 포함한다.
    /// 나머지 파서 상태(is_strict_mode, in_loop 등)는 Parser의 개별 필드로 관리.
    ///
    /// 기본값 주의: allow_in, is_top_level은 기본값이 true.
    pub const Context = packed struct(u8) {
        /// `in` 연산자 허용 여부 (for-in/for-of 초기화절에서는 false로 설정하여
        /// `in`을 관계 연산자가 아닌 for-in 키워드로 파싱)
        allow_in: bool = true,
        /// generator 함수 안에 있는지 (yield 키워드 유효성 검증용)
        in_generator: bool = false,
        /// async 함수 안에 있는지 (await 키워드 유효성 검증용)
        in_async: bool = false,
        /// 함수 본문 안에 있는지 (return 유효성 검증용)
        in_function: bool = false,
        /// 최상위 레벨인지 (top-level await 감지용)
        is_top_level: bool = true,
        /// decorator 파싱 중인지
        in_decorator: bool = false,
        /// TS declare 블록 또는 .d.ts 파일 안인지
        in_ambient: bool = false,
        /// TS 조건부 타입 금지 (infer 절에서 extends를 제약으로 파싱)
        disallow_conditional_types: bool = false,

        /// 기본값: allow_in=true, is_top_level=true, 나머지 false.
        pub const default: Context = .{};

        /// 함수 진입 시 Context(문법 파라미터)를 설정한다.
        /// in_function=true, is_top_level=false, async/generator는 인자로 설정.
        pub fn enterFunction(self: Context, is_async: bool, is_generator: bool) Context {
            var new = self;
            new.in_function = true;
            new.in_async = is_async;
            new.in_generator = is_generator;
            new.is_top_level = false;
            return new;
        }
    };

    /// 함수/메서드 진입 시 저장되는 상태.
    /// enterFunctionContext()로 저장, restoreFunctionContext()로 복원.
    const SavedState = struct {
        ctx: Context,
        is_strict_mode: bool,
        in_loop: bool,
        in_switch: bool,
        has_simple_params: bool,
        for_loop_init: bool,
        in_class_field: bool,
        in_static_initializer: bool,
        allow_new_target: bool,
        allow_super_call: bool,
        allow_super_property: bool,
        in_formal_parameters: bool,
    };

    pub fn init(allocator: std.mem.Allocator, scanner: *Scanner) Parser {
        return .{
            .scanner = scanner,
            .ast = Ast.init(allocator, scanner.source),
            .errors = .empty,
            .deferred_module_errors = .empty,
            .scratch = .empty,
            .param_name_spans = .empty,
            .bracket_stack = blk: {
                var stack: std.ArrayList(BracketInfo) = .empty;
                stack.ensureTotalCapacity(allocator, 8) catch {}; // pre-alloc 실패해도 동작에 지장 없음
                break :blk stack;
            },
            .allocator = allocator,
        };
    }

    /// 파일 확장자에 따라 is_module, is_jsx를 설정한다.
    /// main.zig와 bundler graph.zig에서 중복 없이 사용.
    ///
    /// oxc 방식 Unambiguous 모드:
    /// - .mts/.mjs → 확정적 Module (is_module=true)
    /// - .ts/.tsx → Unambiguous (is_module=true 낙관적 파싱 + 에러 지연)
    /// - .js/.jsx/.cts/.cjs → Script (is_module=false)
    pub fn configureFromExtension(self: *Parser, ext: []const u8) void {
        if (std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".mjs")) {
            // 확정적 Module — import/export 없어도 module
            self.is_module = true;
            self.scanner.is_module = true;
        } else if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx")) {
            // Unambiguous — 낙관적으로 module로 파싱, 파싱 후 확정
            self.is_module = true;
            self.scanner.is_module = true;
            self.is_unambiguous = true;
        }
        if (std.mem.eql(u8, ext, ".ts") or std.mem.eql(u8, ext, ".tsx") or
            std.mem.eql(u8, ext, ".mts") or std.mem.eql(u8, ext, ".cts"))
        {
            self.is_ts = true;
        }
        if (std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".jsx")) {
            self.is_jsx = true;
        }
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit();
        self.errors.deinit(self.allocator);
        self.deferred_module_errors.deinit(self.allocator);
        self.scratch.deinit(self.allocator);
        self.param_name_spans.deinit(self.allocator);
        self.bracket_stack.deinit(self.allocator);
    }

    // ================================================================
    // 토큰 접근 헬퍼
    // ================================================================

    /// 현재 토큰의 Kind.
    pub fn current(self: *const Parser) Kind {
        return self.scanner.token.kind;
    }

    /// 현재 토큰의 Span.
    pub fn currentSpan(self: *const Parser) Span {
        return self.scanner.token.span;
    }

    /// 다음 토큰으로 전진. 여는/닫는 괄호를 자동 추적한다.
    pub fn advance(self: *Parser) !void {
        const kind = self.current();
        // 여는 괄호면 스택에 push
        if (kind == .l_paren or kind == .l_bracket or kind == .l_curly) {
            try self.bracket_stack.append(self.allocator, .{
                .kind = kind,
                .span = self.currentSpan(),
            });
        } else if (kind == .r_paren or kind == .r_bracket or kind == .r_curly) {
            // 닫는 괄호면 스택에서 매칭되는 여는 괄호만 pop.
            // 매칭 안 되면 pop하지 않는다 — 에러 복구 시 스택 오염 방지.
            const expected_open: Kind = switch (kind) {
                .r_paren => .l_paren,
                .r_bracket => .l_bracket,
                .r_curly => .l_curly,
                else => unreachable,
            };
            if (self.bracket_stack.items.len > 0 and
                self.bracket_stack.items[self.bracket_stack.items.len - 1].kind == expected_open)
            {
                _ = self.bracket_stack.pop();
            }
        }
        try self.scanner.next();
    }

    /// 현재 토큰이 expected이면 소비하고 true, 아니면 false.
    pub fn eat(self: *Parser, expected: Kind) !bool {
        if (self.current() == expected) {
            try self.advance();
            return true;
        }
        return false;
    }

    /// 현재 토큰이 expected이면 소비, 아니면 "Expected X but found Y" 에러 추가.
    /// 닫는 괄호를 기대하는 경우, 매칭되는 여는 괄호 위치도 표시한다.
    /// 에러 시 토큰을 advance하지 않음 — 각 루프의 progress guard가 무한 루프를 방지.
    pub fn expect(self: *Parser, expected: Kind) !void {
        if (!try self.eat(expected)) {
            const opening = self.findMatchingOpenBracket(expected);
            try self.errors.append(self.allocator, .{
                .span = self.currentSpan(),
                .message = expected.symbol(),
                .found = self.current().symbol(),
                .related_span = if (opening) |o| o.span else null,
                .related_label = if (opening) |o| switch (o.kind) {
                    .l_paren => "opening '(' is here",
                    .l_bracket => "opening '[' is here",
                    .l_curly => "opening '{' is here",
                    else => null,
                } else null,
            });
        }
    }

    /// 제네릭 여는 꺾쇠 `<` 를 소비한다. (oxc re_lex_ts_l_angle 대응)
    /// `<<`, `<=`, `<<=` 를 `<` + 나머지로 분할한다.
    /// 예: `Array<<T>() => T>` 에서 `<<` → `<` + `<`
    pub fn expectOpeningAngleBracket(self: *Parser) !void {
        switch (self.current()) {
            .l_angle => try self.advance(),
            .shift_left, // <<
            .lt_eq, // <=
            .shift_left_eq, // <<=
            => {
                self.scanner.prev_token_kind = .l_angle;
                self.scanner.current = self.scanner.token.span.start + 1;
                try self.advance();
            },
            else => try self.expect(.l_angle),
        }
    }

    /// 제네릭 닫는 꺾쇠 `>` 를 기대한다. (oxc re_lex_ts_r_angle 대응)
    /// `>>`, `>>>`, `>=`, `>>=`, `>>>=` 를 `>` + 나머지로 분할한다.
    /// 예: `Array<Map<K,V>>` 에서 `>>` → `>` + `>`
    /// 예: `(): A<T>=> 0` 에서 `>=` → `>` + `=`
    pub fn expectClosingAngleBracket(self: *Parser) !void {
        if (self.current() == .r_angle) {
            try self.advance();
        } else if (self.isAtClosingAngleBracket()) {
            // 토큰의 첫 바이트(>)만 소비하고 나머지는 다음 렉싱에서 처리
            self.scanner.prev_token_kind = .r_angle;
            self.scanner.current = self.scanner.token.span.start + 1;
            try self.advance();
        } else {
            try self.expect(.r_angle);
        }
    }

    /// 현재 토큰이 `<` 또는 `<`로 시작하는 복합 토큰인지 확인한다.
    pub fn isAtOpeningAngleBracket(self: *const Parser) bool {
        return switch (self.current()) {
            .l_angle, .shift_left, .lt_eq, .shift_left_eq => true,
            else => false,
        };
    }

    /// 현재 토큰이 `>` 또는 `>`로 시작하는 복합 토큰인지 확인한다.
    pub fn isAtClosingAngleBracket(self: *const Parser) bool {
        return switch (self.current()) {
            .r_angle, .shift_right, .shift_right3, .gt_eq, .shift_right_eq, .shift_right3_eq => true,
            else => false,
        };
    }

    /// ASI (Automatic Semicolon Insertion) 규칙으로 세미콜론을 처리한다.
    /// - 세미콜론이 있으면 소비
    /// - 현재 토큰 앞에 개행이 있으면 OK (ASI)
    /// - 현재 토큰이 } 또는 EOF이면 OK (ASI)
    /// - 그 외: "Expected ';' but found X" + 힌트
    pub fn expectSemicolon(self: *Parser) !void {
        if (try self.eat(.semicolon)) return;
        if (self.scanner.token.has_newline_before) return;
        if (self.current() == .r_curly or self.current() == .eof) return;
        try self.errors.append(self.allocator, .{
            .span = self.currentSpan(),
            .message = ";",
            .found = self.current().symbol(),
            .hint = "Try inserting a semicolon here",
        });
    }

    /// 루프 progress guard: 토큰이 진행되지 않았으면 강제 advance.
    /// EOF에 도달하여 루프를 탈출해야 하면 true 반환.
    /// 사용법: `if (try self.ensureLoopProgress(saved_pos)) break;`
    pub fn ensureLoopProgress(self: *Parser, saved_pos: u32) !bool {
        if (self.scanner.token.span.start == saved_pos) {
            if (self.current() == .eof) return true;
            try self.advance();
        }
        return false;
    }

    /// 에러를 추가한다. 기존 호출부 하위 호환 — found/hint 등은 null.
    pub fn addError(self: *Parser, span: Span, expected: []const u8) !void {
        try self.errors.append(self.allocator, .{
            .span = span,
            .message = expected,
        });
    }

    /// Unambiguous 모드에서 모듈/strict 전용 에러를 지연 수집한다.
    /// 확정적 module이면 즉시 에러 추가, unambiguous면 deferred에 수집.
    /// 파싱 후 resolveModuleKind()에서 모듈 확정 시 병합, 스크립트 확정 시 폐기.
    pub fn addModuleError(self: *Parser, span: Span, message: []const u8) !void {
        if (self.is_unambiguous) {
            try self.deferred_module_errors.append(self.allocator, .{
                .span = span,
                .message = message,
            });
        } else {
            try self.addError(span, message);
        }
    }

    /// Unambiguous 모드 해결: 파싱 완료 후 import/export 유무로 module/script 확정.
    /// module syntax가 있으면 → Module (지연 에러 병합)
    /// module syntax가 없으면 → Script (지연 에러 폐기, is_module=false)
    pub fn resolveModuleKind(self: *Parser) !void {
        if (!self.is_unambiguous) return;

        if (self.has_module_syntax) {
            // Module 확정 — 지연 에러를 본 에러 리스트에 병합
            try self.errors.appendSlice(self.allocator, self.deferred_module_errors.items);
        } else {
            // Script 확정 — 지연 에러 폐기, 모듈 모드 해제
            self.is_module = false;
            self.scanner.is_module = false;
            // strict mode가 "use strict" directive에 의한 것이 아니라
            // module 모드에서 자동 설정된 것이면 해제
            // (directive에 의한 strict는 유지해야 함)
            // 주의: is_strict_mode는 이미 파싱 중에 사용되었으므로
            // 이 시점에서의 해제는 semantic analyzer용
        }

        self.is_unambiguous = false;
        self.deferred_module_errors.clearRetainingCapacity();
    }

    /// 닫는 괄호에 매칭되는 여는 괄호를 bracket_stack에서 찾는다.
    /// expect()에서 닫는 괄호 에러 시 "opened here" 표시용.
    pub fn findMatchingOpenBracket(self: *const Parser, closing: Kind) ?BracketInfo {
        const expected_open: Kind = switch (closing) {
            .r_paren => .l_paren,
            .r_bracket => .l_bracket,
            .r_curly => .l_curly,
            else => return null,
        };
        // 스택 맨 위부터 역순 탐색
        var i: usize = self.bracket_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bracket_stack.items[i].kind == expected_open) {
                return self.bracket_stack.items[i];
            }
        }
        return null;
    }

    /// scratch 버퍼의 현재 위치를 저장한다. 중첩 사용 시 save/restore 패턴.
    /// 사용법:
    ///   const top = self.saveScratch();
    ///   // ... scratch에 append ...
    ///   const items = self.scratch.items[top..];
    ///   // ... items 사용 후 ...
    ///   self.restoreScratch(top);
    pub fn saveScratch(self: *const Parser) usize {
        return self.scratch.items.len;
    }

    pub fn restoreScratch(self: *Parser, top: usize) void {
        self.scratch.shrinkRetainingCapacity(top);
    }

    /// rest parameter가 마지막이 아니면 에러.
    /// spread_element 뒤에 comma가 오면 rest가 마지막이 아닌 것.
    /// 단, ambient context (declare)에서 trailing comma (,...) → ) 는 허용.
    pub fn checkRestParameterLast(self: *Parser, param: NodeIndex) ParseError2!void {
        if (!param.isNone() and self.ast.getNode(param).tag == .spread_element and self.current() == .comma) {
            // ambient context에서 trailing comma (rest 뒤 comma + r_paren)는 허용
            if (self.ctx.in_ambient) {
                const next = try self.peekNextKind();
                if (next == .r_paren) return;
            }
            try self.addError(self.currentSpan(), "Rest parameter must be last formal parameter");
        }
    }

    /// 현재 토큰의 소스 텍스트.
    pub fn tokenText(self: *const Parser) []const u8 {
        return self.scanner.tokenText();
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 true.
    /// TS contextual keyword 판별에 사용 (kw_number 등이 identifier로 토큰화된 후).
    pub fn isContextual(self: *const Parser, name: []const u8) bool {
        return self.current() == .identifier and
            std.mem.eql(u8, self.tokenText(), name);
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 소비하고 true.
    pub fn eatContextual(self: *Parser, name: []const u8) !bool {
        if (self.isContextual(name)) {
            try self.advance();
            return true;
        }
        return false;
    }

    /// isContextual과 동일하지만 여러 이름을 한번에 체크.
    pub fn isContextualAny(self: *const Parser, names: []const []const u8) bool {
        if (self.current() != .identifier) return false;
        const text = self.tokenText();
        for (names) |name| {
            if (std.mem.eql(u8, text, name)) return true;
        }
        return false;
    }

    /// 현재 토큰이 identifier이고 텍스트가 name과 일치하면 소비, 아니면 에러.
    pub fn expectContextual(self: *Parser, name: []const u8) !void {
        if (!try self.eatContextual(name)) {
            try self.addError(self.currentSpan(), name);
        }
    }

    /// strict mode에서 eval/arguments를 바인딩 이름으로 사용하면 에러.
    /// escaped 형태 (\u0065val → "eval")도 검증한다.
    pub fn checkStrictBinding(self: *Parser, span: Span) ParseError2!void {
        if (!self.is_strict_mode) return;
        const text = self.resolveIdentifierText(span);
        if (std.mem.eql(u8, text, "eval") or std.mem.eql(u8, text, "arguments")) {
            try self.addError(span, "Assignment to 'eval' or 'arguments' is not allowed in strict mode");
        }
    }

    pub const rest_init_error = "rest element may not have a default initializer";
    /// object_property의 binary.flags에 설정하여 shorthand-with-default를 표시.
    /// parseObjectProperty에서 마킹, coverObjectExpressionToTarget에서 검증.
    pub const shorthand_with_default: u16 = 0x01;
    /// spread_element의 unary.flags에 설정하여 trailing comma를 표시.
    /// parseArrayExpression에서 마킹, coverArrayExpressionToTarget에서 검증.
    pub const spread_trailing_comma: u16 = 0x01;

    /// binding pattern에서 rest element가 assignment_pattern(= initializer)이면 에러.
    /// parseArrayPattern, parseObjectPattern, parseBindingPattern의 rest 처리에서 공통 사용.
    pub fn checkBindingRestInit(self: *Parser, rest_arg: NodeIndex) ParseError2!void {
        if (rest_arg.isNone()) return;
        const rest_node = self.ast.getNode(rest_arg);
        // binding 위치에서는 assignment_pattern, cover grammar에서는 assignment_expression
        if (rest_node.tag == .assignment_pattern or rest_node.tag == .assignment_expression) {
            try self.addError(rest_node.span, rest_init_error);
        }
    }

    /// identifier의 소스 텍스트가 escaped reserved keyword인지 확인.
    /// 소스에 `\`가 있고, 디코딩하면 reserved keyword이면 에러.
    /// strict mode에서는 escaped strict mode reserved도 에러.
    /// cover grammar 함수 내부 + parseObjectProperty에서 사용.
    pub fn checkIdentifierEscapedKeyword(self: *Parser, span: Span) ParseError2!void {
        // escape가 없으면 검사 불필요
        const raw = self.ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) return;

        const text = self.scanner.decodeIdentifierEscapes(raw) orelse return;
        if (token_mod.keywords.get(text)) |kw| {
            // yield/await는 context-dependent keywords — checkYieldAwaitUse에서 별도 검증.
            if (kw == .kw_yield or kw == .kw_await) return;
            if (kw.isReservedKeyword() or kw.isLiteralKeyword() or
                (self.is_strict_mode and kw.isStrictModeReserved()))
            {
                try self.addError(span, "Keywords cannot contain escape characters");
            }
        }
    }

    /// identifier span의 소스 텍스트를 반환. escape가 있으면 디코딩한 결과를 반환.
    /// 키워드 매칭에 사용 — escape 유무와 관계없이 동일한 resolved text 반환.
    pub fn resolveIdentifierText(self: *Parser, span: Span) []const u8 {
        const text = self.ast.source[span.start..span.end];
        if (std.mem.indexOfScalar(u8, text, '\\') == null) return text;
        return self.scanner.decodeIdentifierEscapes(text) orelse text;
    }

    // ================================================================
    // Cover Grammar: expression → assignment target 재해석 (oxc 방식)
    // ================================================================
    //
    // ECMAScript의 "cover grammar"은 expression과 pattern이 같은 구문 형태를
    // 공유하기 때문에 파서가 expression으로 먼저 파싱한 후, 문맥에 따라
    // assignment target으로 재해석하는 메커니즘이다.
    //
    // 예: `[a, b] = [1, 2]` — 좌변은 array_expression으로 파싱되지만
    //     `=`를 만나는 순간 array destructuring pattern으로 재해석된다.
    //
    // 기존에는 이 재해석을 위한 검증이 6개 함수에 분산되어 있었다.
    // coverExpressionToAssignmentTarget은 이를 단일 재귀 walk로 통합한다.
    //
    // 한 번의 순회에서 검증하는 규칙:
    // 1. 구조적 유효성: identifier, member expr, destructuring만 assignment target
    // 2. rest/spread initializer 금지: [...x = 1] = arr → SyntaxError
    // 3. escaped keyword 금지: ({ v\u0061r }) = x → SyntaxError
    // 4. strict mode eval/arguments 할당 금지
    // 5. parenthesized destructuring 금지: ({x}) = 1 → SyntaxError

    /// expression을 assignment target으로 검증하는 단일 재귀 walk.
    /// 기존의 isValidAssignmentTarget + checkRestInitInAssignmentPattern +
    /// checkSpreadRestInit + checkEscapedKeywordInPattern +
    /// checkStrictAssignmentTarget 5개 함수를 하나로 통합한다.
    ///
    /// cover grammar: expression → assignment target으로 변환.
    /// 태그를 변환하고 (setTag) 검증도 수행한다.
    /// 반환값: true면 valid assignment target, false면 에러를 이미 추가했거나 invalid.
    /// is_top이 true면 최상위 호출 (invalid일 때 "Invalid assignment target" 에러 추가).
    pub fn coverExpressionToAssignmentTarget(self: *Parser, idx: NodeIndex, is_top: bool) ParseError2!bool {
        if (idx.isNone()) return false;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            // 1) identifier — valid target. 태그를 assignment_target_identifier로 변환.
            .identifier_reference => {
                // escaped keyword 검증: v\u0061r → "var"이면 에러
                try self.checkIdentifierEscapedKeyword(node.span);
                // strict mode: eval/arguments에 할당 금지 (checkStrictBinding 내부에서 strict 체크)
                try self.checkStrictBinding(node.span);
                self.ast.setTag(idx, .assignment_target_identifier);
                return true;
            },
            .private_identifier, .private_field_expression => true,

            // 2) member expression — optional chaining이 아니면 valid (태그 유지)
            .static_member_expression, .computed_member_expression => {
                if (self.ast.readExtra(node.data.extra, 2) == 0) return true; // normal (not optional chain)
                // optional chaining (a?.b, a?.[b])은 assignment target이 아님
                if (is_top) try self.addError(node.span, "Invalid assignment target");
                return false;
            },

            // 3) array destructuring — 태그를 array_assignment_target으로 변환 + 자식 재귀
            .array_expression => {
                self.ast.setTag(idx, .array_assignment_target);
                try self.coverArrayExpressionToTarget(node);
                return true;
            },

            // 4) object destructuring — 태그를 object_assignment_target으로 변환 + 자식 재귀
            .object_expression => {
                self.ast.setTag(idx, .object_assignment_target);
                try self.coverObjectExpressionToTarget(node);
                // CoverInitializedName이 destructuring으로 정상 소비됨
                self.has_cover_init_name = false;
                return true;
            },

            // 5) parenthesized expression — 내부를 벗겨서 검증
            .parenthesized_expression => {
                const inner = node.data.unary.operand;
                if (inner.isNone()) {
                    if (is_top) try self.addError(node.span, "Invalid assignment target");
                    return false;
                }
                const inner_tag = self.ast.getNode(inner).tag;
                // ({x}) = 1, ([x]) = 1 → parenthesized destructuring 금지
                if (inner_tag == .array_expression or inner_tag == .object_expression) {
                    try self.addError(node.span, "Invalid assignment target");
                    return false;
                }
                // (x) = 1 → 내부가 simple target이면 OK
                return try self.coverExpressionToAssignmentTarget(inner, is_top);
            },

            // 6) 이미 변환된 assignment target 태그는 유지
            .assignment_target_identifier,
            .array_assignment_target,
            .object_assignment_target,
            => true,

            // 6b) TS as/satisfies expression — 내부 expression을 assignment target으로 검증
            // (z as any) = 1 → z가 valid target이면 OK (esbuild/TS 호환)
            .ts_as_expression, .ts_satisfies_expression => {
                const inner = node.data.binary.left;
                return try self.coverExpressionToAssignmentTarget(inner, is_top);
            },

            // 7) meta_property (import.meta, new.target) — 절대로 assignment target이 될 수 없음.
            //    is_top 여부와 무관하게 항상 에러. else 분기는 is_top=false일 때 에러를 내지 않으므로
            //    destructuring 내부([import.meta] = arr)에서 잘못 통과하는 것을 방지.
            .meta_property => {
                try self.addError(node.span, "Invalid assignment target");
                return false;
            },

            else => {
                if (is_top) try self.addError(node.span, "Invalid assignment target");
                return false;
            },
        };
    }

    /// spread element의 operand를 검증하는 cover grammar 헬퍼.
    /// rest에 initializer가 있으면 에러를 내고, operand를 재귀 검증한다.
    /// coverArrayExpressionToTarget과 coverObjectExpressionToTarget에서 공통 사용.
    pub fn coverSpreadElementToTarget(self: *Parser, spread_idx: NodeIndex, operand_idx: NodeIndex) ParseError2!void {
        const operand = self.ast.getNode(operand_idx);
        if (operand.tag == .assignment_expression) {
            try self.addError(operand.span, rest_init_error);
        }
        // spread_element → assignment_target_rest로 변환
        self.ast.setTag(spread_idx, .assignment_target_rest);
        _ = try self.coverExpressionToAssignmentTarget(operand_idx, true);
    }

    /// array expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
    /// 각 요소의 spread rest-init 금지 + nested pattern 재귀 검증.
    pub fn coverArrayExpressionToTarget(self: *Parser, node: Node) ParseError2!void {
        const list = node.data.list;
        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
            if (elem_idx.isNone()) continue; // elision (none)
            const elem = self.ast.getNode(elem_idx);
            if (elem.tag == .elision) continue; // elision node — destructuring에서는 무시
            switch (elem.tag) {
                .spread_element => {
                    // rest는 마지막 요소여야 함: [...x, y] → SyntaxError
                    if (i + 1 < list.len) {
                        try self.addError(elem.span, "Rest element must be last element");
                    }
                    // rest 뒤 trailing comma 금지: [...x,] → SyntaxError
                    // parseArrayExpression에서 spread_trailing_comma로 마킹됨
                    if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                        try self.addError(elem.span, "Rest element may not have a trailing comma");
                    }
                    try self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
                },
                .assignment_expression => {
                    // [x = 1] → assignment_target_with_default로 변환
                    self.ast.setTag(elem_idx, .assignment_target_with_default);
                    _ = try self.coverExpressionToAssignmentTarget(elem.data.binary.left, true);
                },
                else => {
                    // identifier, nested array/object/member 등 → 재귀 검증
                    _ = try self.coverExpressionToAssignmentTarget(elem_idx, true);
                },
            }
        }
    }

    /// object expression 내부를 assignment target으로 검증 (coverExpressionToAssignmentTarget 헬퍼).
    /// 각 프로퍼티의 shorthand escaped keyword + strict eval/arguments + spread rest-init + nested value 재귀 검증.
    pub fn coverObjectExpressionToTarget(self: *Parser, node: Node) ParseError2!void {
        const list = node.data.list;
        var i: u32 = 0;
        while (i < list.len) : (i += 1) {
            const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
            if (elem_idx.isNone()) continue;
            const elem = self.ast.getNode(elem_idx);
            if (elem.tag == .object_property) {
                const is_shorthand_default = (elem.data.binary.flags & shorthand_with_default) != 0;
                if (!elem.data.binary.left.isNone() and elem.data.binary.right.isNone()) {
                    // shorthand without value: { eval } — right가 none인 경우
                    // parseObjectProperty에서 shorthand는 value를 생성하지 않으므로 right=none
                    const key_span = self.ast.getNode(elem.data.binary.left).span;
                    try self.checkIdentifierEscapedKeyword(key_span);
                    try self.checkStrictBinding(key_span);
                    self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                } else if (!elem.data.binary.left.isNone() and !elem.data.binary.right.isNone()) {
                    // shorthand 검증: key와 value가 같은 span이면 shorthand
                    const key_span = self.ast.getNode(elem.data.binary.left).span;
                    const val_node = self.ast.getNode(elem.data.binary.right);
                    const is_shorthand = key_span.start == val_node.span.start and key_span.end == val_node.span.end;
                    if (is_shorthand) {
                        try self.checkIdentifierEscapedKeyword(key_span);
                        // strict mode: shorthand에서 eval/arguments 할당 금지
                        try self.checkStrictBinding(key_span);
                        // shorthand → assignment_target_property_identifier
                        self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                    } else if (is_shorthand_default) {
                        // shorthand with default: { eval = 0 } — key가 target, value가 default
                        // key의 eval/arguments 검증이 필요 (strict mode)
                        try self.checkIdentifierEscapedKeyword(key_span);
                        try self.checkStrictBinding(key_span);
                        self.ast.setTag(elem_idx, .assignment_target_property_identifier);
                        // value(default)는 assignment target이 아니므로 검증하지 않음
                    } else {
                        // long-form → assignment_target_property_property
                        self.ast.setTag(elem_idx, .assignment_target_property_property);
                        // value가 assignment_expression이면 default-value 구문:
                        // { key: target = default } → target을 검증, default는 검증하지 않음
                        if (val_node.tag == .assignment_expression) {
                            self.ast.setTag(elem.data.binary.right, .assignment_target_with_default);
                            _ = try self.coverExpressionToAssignmentTarget(val_node.data.binary.left, true);
                        } else {
                            // value를 재귀 검증 (nested pattern일 수 있음)
                            _ = try self.coverExpressionToAssignmentTarget(elem.data.binary.right, true);
                        }
                    }
                }
            } else if (elem.tag == .spread_element) {
                // rest는 마지막 요소여야 함: {...x, y} → SyntaxError
                if (i + 1 < list.len) {
                    try self.addError(elem.span, "Rest element must be last element");
                }
                // object rest: {...x} = obj
                try self.coverSpreadElementToTarget(elem_idx, elem.data.unary.operand);
            } else if (elem.tag == .method_definition) {
                // method/getter/setter/async/generator는 destructuring target이 아님
                try self.addError(elem.span, "Invalid assignment target");
            }
        }
    }

    /// cover grammar 표현식에서 바인딩 이름의 span을 재귀 수집하여 중복 검사한다.
    /// 중복 발견 시 즉시 에러를 추가한다.
    pub fn collectCoverParamNames(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .identifier_reference, .binding_identifier, .assignment_target_identifier => {
                const name = self.ast.source[node.span.start..node.span.end];
                // 이전에 수집된 이름과 비교하여 중복 검사
                // param_name_spans를 사용 — coverExpressionToArrowParams에서 초기화
                for (self.param_name_spans.items) |prev_span| {
                    const prev_name = self.ast.source[prev_span.start..prev_span.end];
                    if (std.mem.eql(u8, name, prev_name)) {
                        try self.addError(node.span, "Duplicate parameter name");
                        return;
                    }
                }
                try self.param_name_spans.append(self.allocator, node.span);
            },
            .parenthesized_expression => try self.collectCoverParamNames(node.data.unary.operand),
            .sequence_expression => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectCoverParamNames(elem_idx);
                }
            },
            .object_expression, .array_expression, .object_assignment_target, .array_assignment_target => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectCoverParamNames(elem_idx);
                }
            },
            .assignment_target_property_identifier => {
                // shorthand property (identifier): { x }, { x = default }
                // left = key(identifier_reference) = 바인딩, right = default value 또는 none
                // 항상 left(key)에서 바인딩 이름을 수집한다. right는 default value이므로 수집하지 않는다.
                try self.collectCoverParamNames(node.data.binary.left);
            },
            .object_property => {
                // cover grammar 변환 전의 object property.
                // shorthand_with_default({ x = val }): left=key(바인딩), right=default value
                // shorthand({ x }): right=none, left=key(바인딩)
                // long-form({ key: value }): left=key, right=value(바인딩)
                const is_shorthand_default = (node.data.binary.flags & shorthand_with_default) != 0;
                if (node.data.binary.right.isNone()) {
                    // shorthand: { x } — key가 바인딩
                    try self.collectCoverParamNames(node.data.binary.left);
                } else if (is_shorthand_default) {
                    // shorthand with default: { x = val } — key가 바인딩, value는 default
                    try self.collectCoverParamNames(node.data.binary.left);
                } else {
                    // long-form: { key: value } — value가 바인딩
                    try self.collectCoverParamNames(node.data.binary.right);
                }
            },
            .assignment_target_property_property => {
                // long-form property: { key: target } 또는 { key: target = default }
                // right(value)에서 바인딩 이름을 수집한다.
                try self.collectCoverParamNames(node.data.binary.right);
            },
            .binding_property => {
                try self.collectCoverParamNames(node.data.binary.right);
            },
            .assignment_expression, .assignment_pattern, .assignment_target_with_default => {
                // default value: left = binding, right = default_value
                try self.collectCoverParamNames(node.data.binary.left);
                // default value 내부의 yield/await 검사 (이름 수집하지 않고 검사만)
                try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            .spread_element, .assignment_target_rest, .binding_rest_element, .rest_element => {
                try self.collectCoverParamNames(node.data.unary.operand);
            },
            else => {},
        }
    }

    /// expression이 arrow function 파라미터로 유효한 형태인지 확인한다.
    /// parenthesized_expression, identifier_reference 등만 arrow 파라미터가 될 수 있다.
    /// call_expression, member_expression 등은 불가능.
    pub fn isValidArrowParamForm(self: *const Parser, idx: NodeIndex) bool {
        if (idx.isNone()) return false;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .parenthesized_expression, .identifier_reference, .binding_identifier => true,
            else => false,
        };
    }

    /// async arrow 파라미터에서 'await' 식별자 사용을 금지한다.
    /// async arrow의 파라미터는 async context 진입 전에 파싱되므로 await가 identifier로 파싱된다.
    /// 이 함수는 cover grammar 변환 후 호출하여 identifier 이름이 "await"인 경우를 검출한다.
    pub fn checkAsyncArrowParamsForAwait(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .identifier_reference, .binding_identifier, .assignment_target_identifier => {
                const name = self.ast.source[node.span.start..node.span.end];
                if (std.mem.eql(u8, name, "await")) {
                    try self.addError(node.span, "'await' is not allowed in async arrow function parameters");
                }
            },
            .parenthesized_expression, .spread_element, .assignment_target_rest => {
                try self.checkAsyncArrowParamsForAwait(node.data.unary.operand);
            },
            .sequence_expression,
            .array_expression,
            .object_expression,
            .array_assignment_target,
            .object_assignment_target,
            => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.checkAsyncArrowParamsForAwait(elem_idx);
                }
            },
            .assignment_expression,
            .assignment_pattern,
            .assignment_target_with_default,
            .object_property,
            .assignment_target_property_identifier,
            .assignment_target_property_property,
            .binding_property,
            => {
                try self.checkAsyncArrowParamsForAwait(node.data.binary.left);
                try self.checkAsyncArrowParamsForAwait(node.data.binary.right);
            },
            // 중첩 arrow의 파라미터에도 await 사용 금지
            .arrow_function_expression => {
                try self.checkAsyncArrowParamsForAwait(node.data.binary.left);
            },
            else => {},
        }
    }

    /// arrow 파라미터 default value 내부에 yield/await가 있는지 검사한다.
    /// 이름 수집은 하지 않고 yield/await expression만 검출한다.
    pub fn checkCoverParamDefaultForYieldAwait(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        if (@intFromEnum(idx) >= self.ast.nodes.items.len) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            .yield_expression => {
                try self.addError(node.span, "'yield' is not allowed in arrow function parameters");
            },
            .await_expression => {
                try self.addError(node.span, "'await' is not allowed in arrow function parameters");
            },
            // unary node — operand만 검사
            .parenthesized_expression,
            .spread_element,
            => try self.checkCoverParamDefaultForYieldAwait(node.data.unary.operand),
            // unary/update: extra = [operand, operator_and_flags]
            .unary_expression,
            .update_expression,
            => {
                const e = node.data.extra;
                if (e < self.ast.extra_data.items.len) {
                    try self.checkCoverParamDefaultForYieldAwait(@enumFromInt(self.ast.extra_data.items[e]));
                }
            },
            // list node — 각 요소 검사
            .sequence_expression,
            .array_expression,
            .object_expression,
            => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.checkCoverParamDefaultForYieldAwait(elem_idx);
                }
            },
            // binary node — 양쪽 자식 검사
            .assignment_expression,
            .binary_expression,
            .logical_expression,
            .object_property,
            => {
                try self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
                try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            // conditional은 ternary이지만 binary data 사용 (condition=left, consequent/alternate 조합=right)
            .conditional_expression => {
                try self.checkCoverParamDefaultForYieldAwait(node.data.binary.left);
                try self.checkCoverParamDefaultForYieldAwait(node.data.binary.right);
            },
            // 리프 노드 (identifier, literal 등)나 기타 — 더 이상 탐색 불필요
            else => {},
        }
    }

    /// arrow function 파라미터를 cover grammar으로 검증.
    /// parenthesized/sequence expression을 풀어서 각 요소에
    /// coverExpressionToAssignmentTarget을 위임한다.
    ///
    /// 기존 checkRestInitInArrowParams를 대체한다.
    pub fn coverExpressionToArrowParams(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .parenthesized_expression) {
            // (expr) → 내부를 다시 풀기
            // return으로 종료: 재귀 호출 내부에서 collectCoverParamNames가 실행되므로
            // 여기서 다시 실행하면 중복 에러가 발생한다.
            return self.coverExpressionToArrowParams(node.data.unary.operand);
        } else if (node.tag == .sequence_expression) {
            // (a, b, c) → 각 요소를 개별 검증
            const list = node.data.list;
            var i: u32 = 0;
            while (i < list.len) : (i += 1) {
                const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                const elem = self.ast.getNode(elem_idx);
                if (elem.tag == .spread_element) {
                    // rest 파라미터: 마지막 요소여야 하고 initializer 금지, trailing comma 금지
                    if (i + 1 < list.len) {
                        try self.addError(elem.span, "Rest element must be last element");
                    }
                    if ((elem.data.unary.flags & spread_trailing_comma) != 0) {
                        try self.addError(elem.span, "Rest element may not have a trailing comma");
                    }
                    try self.checkBindingRestInit(elem.data.unary.operand);
                    // rest의 operand도 valid assignment target이어야 함
                    _ = try self.coverExpressionToAssignmentTarget(elem.data.unary.operand, false);
                } else {
                    _ = try self.coverExpressionToAssignmentTarget(elem_idx, false);
                }
            }
        } else if (node.tag == .spread_element) {
            // 단일 rest 파라미터: (...x) → initializer 금지 + trailing comma 금지
            if ((node.data.unary.flags & spread_trailing_comma) != 0) {
                try self.addError(node.span, "Rest element may not have a trailing comma");
            }
            try self.checkBindingRestInit(node.data.unary.operand);
            _ = try self.coverExpressionToAssignmentTarget(node.data.unary.operand, false);
        } else {
            // 단일 expression → 직접 검증
            _ = try self.coverExpressionToAssignmentTarget(idx, false);
        }
        // arrow 파라미터 중복 검사: (x, {x}) => 1 등
        // cover grammar 변환 후에 수행 (변환된 태그도 처리하므로)
        self.param_name_spans.clearRetainingCapacity();
        try self.collectCoverParamNames(idx);
    }

    /// 키워드를 바인딩 위치에서 사용할 때의 검증.
    /// ECMAScript 12.1.1: reserved keyword, strict mode reserved, contextual keywords.
    /// escaped 형태 (\u0061wait 등)도 동일하게 검증한다.
    pub fn checkKeywordBinding(self: *Parser) ParseError2!void {
        // await는 조건부 예약어 — async/module에서만 금지, script에서는 식별자로 사용 가능
        // yield도 조건부 — generator/strict에서만 금지
        // 둘 다 checkYieldAwaitUse에서 처리
        if (self.current() == .kw_await or self.current() == .kw_yield) {
            _ = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
        } else if (self.current().isReservedKeyword() or self.current().isLiteralKeyword()) {
            try self.addError(self.currentSpan(), "Reserved word cannot be used as identifier");
        } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
            // Unambiguous 모드: strict가 module 자동이면 지연
            try self.addModuleError(self.currentSpan(), "Reserved word in strict mode cannot be used as identifier");
        } else if (self.current() == .escaped_keyword) {
            // escaped reserved keyword는 식별자로 사용 불가 (예: \u0061wait in script)
            // 단, escaped await는 script mode의 non-async에서는 허용
            const is_escaped_await = self.isEscapedKeyword("await");
            if (is_escaped_await) {
                if ((self.is_module and !self.in_namespace) or self.ctx.in_async) {
                    // Unambiguous: module에서만 에러이므로 지연
                    try self.addModuleError(self.currentSpan(), "'await' cannot be used as identifier in this context");
                }
            } else {
                try self.addError(self.currentSpan(), "Keywords cannot contain escape characters");
            }
        } else if (self.current() == .escaped_strict_reserved) {
            // escaped strict reserved는 strict mode에서 금지
            // yield/await 컨텍스트 에러가 우선
            const had_error = try self.checkYieldAwaitUse(self.currentSpan(), "identifier");
            if (!had_error and self.is_strict_mode) {
                try self.addError(self.currentSpan(), "Keywords cannot contain escape characters");
            }
        }
    }

    /// yield/await를 식별자/레이블/바인딩으로 사용할 때의 검증.
    /// ECMAScript 13.1.1: yield는 [Yield] 또는 strict mode에서, await는 [Await] 또는 module에서 금지.
    /// context_noun: "identifier", "label" 등 — 에러 메시지에 사용 (comptime 문자열 연결).
    /// 에러를 추가했으면 true, 아니면 false를 반환한다.
    /// yield/await + strict mode 예약어를 식별자 위치에서 검증한다.
    /// ECMAScript 12.1.1: yield/await는 컨텍스트에 따라 식별자 사용 금지,
    /// strict mode에서는 implements/interface/let/package 등도 금지.
    pub fn checkIdentifierKeywordUse(self: *Parser, span: Span) ParseError2!void {
        if (self.current() == .kw_yield or self.current() == .kw_await) {
            _ = try self.checkYieldAwaitUse(span, "identifier");
        } else if (self.is_strict_mode and self.current().isStrictModeReserved()) {
            // Unambiguous 모드: strict가 module 자동이면 지연
            try self.addModuleError(span, "Reserved word in strict mode cannot be used as identifier");
        }
    }

    pub fn checkYieldAwaitUse(self: *Parser, span: Span, comptime context_noun: []const u8) ParseError2!bool {
        // yield/await는 escaped 형태(yi\u0065ld)도 동일 규칙 적용 (ECMAScript 12.1.1)
        // await는 reserved keyword이므로 escaped_keyword로 분류됨 → 여기서는 yield만 처리
        const is_yield = self.current() == .kw_yield or
            (self.current() == .escaped_strict_reserved and self.isEscapedKeyword("yield"));
        const is_await = self.current() == .kw_await;

        if (is_yield) {
            if (self.ctx.in_generator) {
                try self.addError(span, "'yield' cannot be used as " ++ context_noun ++ " in generator");
                return true;
            } else if (self.is_strict_mode) {
                // Unambiguous 모드에서 strict가 module 자동 설정이면 지연
                // (script 확정 시 yield는 식별자로 허용)
                try self.addModuleError(span, "'yield' cannot be used as " ++ context_noun ++ " in strict mode");
                return true;
            }
        } else if (is_await) {
            if (self.ctx.in_async) {
                try self.addError(span, "'await' cannot be used as " ++ context_noun ++ " in async function");
                return true;
            } else if (self.is_module and !self.in_namespace) {
                // namespace body 안에서는 await를 식별자로 허용
                // (namespace는 IIFE로 변환되므로 top-level module code가 아님)
                // Unambiguous 모드에서는 지연 (script 확정 시 await는 식별자)
                try self.addModuleError(span, "'await' cannot be used as " ++ context_noun ++ " in module code");
                return true;
            }
        }
        return false;
    }

    /// escaped_strict_reserved 토큰이 특정 키워드인지 확인한다.
    /// Scanner.decodeIdentifierEscapes로 디코딩 후 비교.
    pub fn isEscapedKeyword(self: *Parser, comptime expected: []const u8) bool {
        const decoded = self.scanner.decodeIdentifierEscapes(self.tokenText()) orelse return false;
        return std.mem.eql(u8, decoded, expected);
    }

    // ================================================================
    // 컨텍스트 저장/복원 (D051: 함수 경계에서 컨텍스트 리셋)
    // ================================================================
    //
    // 함수 진입 시 SavedState로 ctx(u8) + 관련 Parser 필드를 저장/복원한다.
    // allow_in 등 Context만 변경하는 경우는 ctx를 직접 save/restore한다.

    /// 함수 컨텍스트를 설정한다.
    /// 현재 ctx와 관련 Parser 필드를 SavedState에 저장하고, 함수 진입 상태로 변경한다.
    /// 함수/메서드/arrow 진입 시 호출하고, 본문 파싱 후 restoreFunctionContext()로 복원.
    pub fn enterFunctionContext(self: *Parser, is_async: bool, is_generator: bool) SavedState {
        const saved = SavedState{
            .ctx = self.ctx,
            .is_strict_mode = self.is_strict_mode,
            .in_loop = self.in_loop,
            .in_switch = self.in_switch,
            .has_simple_params = self.has_simple_params,
            .for_loop_init = self.for_loop_init,
            .in_class_field = self.in_class_field,
            .in_static_initializer = self.in_static_initializer,
            .allow_new_target = self.allow_new_target,
            .allow_super_call = self.allow_super_call,
            .allow_super_property = self.allow_super_property,
            .in_formal_parameters = self.in_formal_parameters,
        };
        self.ctx = self.ctx.enterFunction(is_async, is_generator);
        // Parser 필드 리셋 — 함수 경계에서 초기 상태로
        self.in_loop = false;
        self.in_switch = false;
        self.has_simple_params = true; // 기본값은 true (checkSimpleParams에서 갱신)
        self.for_loop_init = false;
        self.allow_super_call = false;
        self.allow_super_property = false;
        self.in_class_field = false;
        self.in_static_initializer = false;
        self.allow_new_target = true; // 일반 함수에서는 new.target 허용
        self.in_formal_parameters = false;
        return saved;
    }

    /// 함수 컨텍스트를 복원한다 (enterFunctionContext와 쌍).
    pub fn restoreFunctionContext(self: *Parser, saved: SavedState) void {
        self.ctx = saved.ctx;
        self.is_strict_mode = saved.is_strict_mode;
        self.in_loop = saved.in_loop;
        self.in_switch = saved.in_switch;
        self.has_simple_params = saved.has_simple_params;
        self.for_loop_init = saved.for_loop_init;
        self.in_class_field = saved.in_class_field;
        self.in_static_initializer = saved.in_static_initializer;
        self.allow_new_target = saved.allow_new_target;
        self.allow_super_call = saved.allow_super_call;
        self.allow_super_property = saved.allow_super_property;
        self.in_formal_parameters = saved.in_formal_parameters;
    }

    /// Context(u8)를 복원한다 (enterAllowInContext 등과 쌍).
    pub fn restoreContext(self: *Parser, saved: Context) void {
        self.ctx = saved;
    }

    /// `in` 연산자 허용/금지 컨텍스트에 진입한다.
    /// ECMAScript 문법의 [+In]/[~In] 파라미터 전환에 사용.
    /// 반환값을 restoreContext()에 전달하여 복원.
    pub fn enterAllowInContext(self: *Parser, allow: bool) Context {
        const saved = self.ctx;
        self.ctx.allow_in = allow;
        return saved;
    }

    /// 현재 토큰이 "use strict" directive인지 확인한다.
    /// directive prologue에서 호출 — tokenText()는 따옴표를 포함하므로 내부를 비교.
    pub fn isUseStrictDirective(self: *const Parser) bool {
        if (self.current() != .string_literal) return false;
        const text = self.tokenText();
        // "use strict" 또는 'use strict' — 따옴표 포함 길이 = "use strict".len + 2 = 12
        if (text.len < "\"use strict\"".len) return false;
        const inner = text[1 .. text.len - 1];
        return std.mem.eql(u8, inner, "use strict");
    }

    /// 루프 본문을 파싱한다. in_loop를 save/restore.
    pub fn parseLoopBody(self: *Parser) ParseError2!NodeIndex {
        const saved_in_loop = self.in_loop;
        self.in_loop = true;
        const body = try self.parseStatementChecked(true);
        self.in_loop = saved_in_loop;

        // ECMAScript 14.7.5: It is a Syntax Error if IsLabelledFunction(Statement) is true.
        // 반복문의 body가 labelled function이면 에러 (중첩 label도 재귀 검사).
        // Annex B의 labelled function 예외는 반복문 body에서 적용되지 않는다.
        try self.checkLabelledFunction(body);

        return body;
    }

    /// IsLabelledFunction 검사: labeled statement을 재귀적으로 따라가서
    /// 최종 body가 function declaration이면 에러를 발생시킨다.
    pub fn checkLabelledFunction(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        if (node.tag == .labeled_statement) {
            // labeled_statement의 body는 binary.right에 저장됨
            const inner = node.data.binary.right;
            const inner_node = self.ast.getNode(inner);
            if (inner_node.tag == .function_declaration) {
                try self.addError(inner_node.span, "Labelled function declaration is not allowed in loop body");
            } else if (inner_node.tag == .labeled_statement) {
                // 중첩 label: label1: label2: function f() {}
                try self.checkLabelledFunction(inner);
            }
        }
    }

    /// 파라미터 리스트가 simple인지 검사한다.
    /// simple = 모든 파라미터가 binding_identifier (destructuring, default, rest 없음)
    /// arrow function의 cover grammar 파라미터가 simple인지 확인한다.
    /// simple = 모든 파라미터가 plain identifier (destructuring, default, rest 없음).
    /// "use strict" + non-simple params → SyntaxError (ECMAScript 14.2.1).
    pub fn isSimpleArrowParams(self: *const Parser, param_idx: NodeIndex) bool {
        if (param_idx.isNone()) return true; // () → simple
        const node = self.ast.getNode(param_idx);
        return switch (node.tag) {
            // 단일 식별자: x => ... → simple
            .binding_identifier, .identifier_reference, .assignment_target_identifier => true,
            // 괄호 표현식: (x) → 내부 확인
            .parenthesized_expression => {
                if (node.data.unary.operand.isNone()) return true; // () → simple
                return self.isSimpleArrowParams(node.data.unary.operand);
            },
            // 콤마 리스트: (a, b, c) → 각 요소 확인
            .sequence_expression => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    if (!self.isSimpleArrowParams(elem_idx)) return false;
                }
                return true;
            },
            // destructuring, default, rest, spread → non-simple
            else => false,
        };
    }

    pub fn checkSimpleParams(self: *const Parser, scratch_top: usize) bool {
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

    /// arrow function은 항상 UniqueFormalParameters — 조건 없이 검사.
    pub fn checkDuplicateArrowFormalParams(self: *Parser, scratch_top: usize) ParseError2!void {
        try self.checkDuplicateParamsCore(scratch_top);
    }

    /// 일반 함수 중복 파라미터 검사.
    /// sloppy mode + simple params인 일반 function만 허용, 나머지는 에러.
    pub fn checkDuplicateParams(self: *Parser, scratch_top: usize) ParseError2!void {
        const must_check = self.is_strict_mode or !self.has_simple_params or
            self.ctx.in_generator or self.ctx.in_async;
        if (!must_check) return;
        try self.checkDuplicateParamsCore(scratch_top);
    }

    /// 파라미터 목록에서 중복 바인딩 이름을 찾아 에러를 추가한다.
    fn checkDuplicateParamsCore(self: *Parser, scratch_top: usize) ParseError2!void {
        const params = self.scratch.items[scratch_top..];
        self.param_name_spans.clearRetainingCapacity();
        for (params) |param_idx| {
            const names_before = self.param_name_spans.items.len;
            try self.collectBoundNames(param_idx);
            const names_after = self.param_name_spans.items.len;
            var j: usize = names_before;
            while (j < names_after) : (j += 1) {
                const name_span = self.param_name_spans.items[j];
                const name = self.ast.source[name_span.start..name_span.end];
                for (self.param_name_spans.items[0..j]) |prev_span| {
                    const prev_name = self.ast.source[prev_span.start..prev_span.end];
                    if (std.mem.eql(u8, name, prev_name)) {
                        try self.addError(name_span, "Duplicate parameter name");
                        break;
                    }
                }
            }
        }
        self.param_name_spans.clearRetainingCapacity();
    }

    /// 바인딩 패턴 노드에서 모든 바인딩 이름의 Span을 재귀적으로 수집한다.
    /// ECMAScript 8.6.3 BoundNames 알고리즘에 해당.
    ///
    /// 지원하는 패턴:
    ///   - binding_identifier (a)              → Span 1개 추가
    ///   - assignment_pattern (a = 1)           → left 재귀
    ///   - formal_parameter (TS: public a)      → operand 재귀
    ///   - spread_element / rest_element (...a) → operand 재귀
    ///   - array_pattern ([a, b, [c]])           → 각 element 재귀
    ///   - object_pattern ({a, b: c})            → 각 property 재귀
    ///   - binding_property ({key: value})       → right(value) 재귀
    ///   - elision / invalid                    → 무시
    pub fn collectBoundNames(self: *Parser, idx: NodeIndex) ParseError2!void {
        if (idx.isNone()) return;
        const node = self.ast.getNode(idx);
        switch (node.tag) {
            // 단말 노드: 이름 1개 추가
            .binding_identifier => {
                try self.param_name_spans.append(self.allocator, node.span);
            },
            // x = default → 왼쪽이 실제 바인딩
            .assignment_pattern => {
                try self.collectBoundNames(node.data.binary.left);
            },
            // TS parameter property (public x) → operand가 실제 바인딩
            .formal_parameter => {
                try self.collectBoundNames(node.data.unary.operand);
            },
            // ...rest → operand가 실제 바인딩 (배열/객체 패턴 포함)
            .spread_element, .rest_element, .binding_rest_element => {
                try self.collectBoundNames(node.data.unary.operand);
            },
            // [a, b, [c, d]] → 각 element를 재귀적으로 처리
            .array_pattern => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const elem_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectBoundNames(elem_idx);
                }
            },
            // {a, b: c, ...rest} → 각 property를 재귀적으로 처리
            .object_pattern => {
                const list = node.data.list;
                var i: u32 = 0;
                while (i < list.len) : (i += 1) {
                    const prop_idx: NodeIndex = @enumFromInt(self.ast.extra_data.items[list.start + i]);
                    try self.collectBoundNames(prop_idx);
                }
            },
            // {key: value} → right(value)가 실제 바인딩 패턴
            // shorthand {a} 도 binding_property: left=key(binding_identifier), right=value(binding_identifier)
            .binding_property => {
                try self.collectBoundNames(node.data.binary.right);
            },
            // elision, invalid 등 — 바인딩 없음, 무시
            else => {},
        }
    }

    /// 파라미터 노드에서 단일 바인딩 이름의 Span을 추출한다.
    /// binding_identifier, assignment_pattern(= default), formal_parameter(TS modifier),
    /// spread_element(...rest) 등 단일 이름을 반환하는 형태만 처리.
    /// destructuring([a,b], {a,b})처럼 이름이 여럿인 경우는 null 반환.
    /// 중복 파라미터 검사에는 collectBoundNames를 사용할 것.
    pub fn extractParamName(self: *const Parser, idx: NodeIndex) ?Span {
        if (idx.isNone()) return null;
        const node = self.ast.getNode(idx);
        return switch (node.tag) {
            .binding_identifier => node.span,
            // x = default → left가 binding name
            .assignment_pattern => self.extractParamName(node.data.binary.left),
            // TS parameter property (public x 등) → operand가 binding
            .formal_parameter => self.extractParamName(node.data.unary.operand),
            // rest parameter (...x) → operand가 binding
            .spread_element => self.extractParamName(node.data.unary.operand),
            // destructuring([a,b], {a,b})은 이름이 여럿 — collectBoundNames 사용
            else => null,
        };
    }

    /// "use strict" directive가 발견된 후 함수 이름이 eval/arguments인지 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments를 바인딩 이름으로 사용 금지.
    pub fn checkStrictFunctionName(self: *Parser, name_idx: NodeIndex) ParseError2!void {
        if (name_idx.isNone()) return;
        const node = self.ast.getNode(name_idx);
        if (node.tag != .binding_identifier) return;
        try self.checkStrictBinding(node.span);
    }

    /// "use strict" directive가 발견된 후 파라미터 이름을 소급 검증.
    /// ECMAScript 14.1.2: strict mode에서 eval/arguments + 중복 파라미터 금지.
    /// destructuring 패턴 안의 이름도 재귀적으로 검사한다.
    pub fn checkStrictParamNames(self: *Parser, scratch_top: usize) ParseError2!void {
        const params = self.scratch.items[scratch_top..];
        for (params) |param_idx| {
            // collectBoundNames로 destructuring 안의 이름도 포함하여 모두 검사
            self.param_name_spans.clearRetainingCapacity();
            try self.collectBoundNames(param_idx);
            for (self.param_name_spans.items) |name_span| {
                try self.checkStrictBinding(name_span);
            }
        }
        self.param_name_spans.clearRetainingCapacity();
        // 중복 파라미터도 소급 검사 (simple params + sloppy에서는 허용이지만 strict에서는 금지)
        try self.checkDuplicateParams(scratch_top);
    }

    /// 함수 선언의 본문을 파싱한다 (닫는 `}` 뒤의 `/`는 regexp로 토큰화).
    pub fn parseFunctionBody(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(false);
    }

    /// 표현식 컨텍스트에서 함수 본문을 파싱한다.
    /// 닫는 `}` 뒤의 `/`가 division으로 올바르게 토큰화된다.
    pub fn parseFunctionBodyExpr(self: *Parser) ParseError2!NodeIndex {
        return self.parseFunctionBodyInner(true);
    }

    pub fn parseFunctionBodyInner(self: *Parser, in_expression: bool) ParseError2!NodeIndex {
        const start = self.currentSpan().start;
        try self.expect(.l_curly);

        var stmts: std.ArrayList(NodeIndex) = .empty;
        defer stmts.deinit(self.allocator);

        // directive prologue: 본문 시작의 문자열 리터럴 expression statement 중 "use strict" 감지
        var in_directive_prologue = true;
        // directive prologue에서 "use strict" 이전의 문자열에 legacy octal이 있으면
        // retroactive하게 에러 보고 (ECMAScript 12.8.4.1)
        var has_prologue_octal = false;
        var prologue_octal_span: Span = Span.EMPTY;

        while (self.current() != .r_curly and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            if (in_directive_prologue) {
                if (self.isUseStrictDirective()) {
                    // non-simple parameters + "use strict" → 에러
                    // ECMAScript 14.1.2: function with non-simple parameter list
                    // shall not contain a Use Strict Directive
                    if (!self.has_simple_params) {
                        try self.addError(self.currentSpan(), "\"use strict\" not allowed in function with non-simple parameters");
                    }
                    self.is_strict_mode = true;
                    // "use strict" 이전에 octal escape가 있었으면 retroactive 에러
                    if (has_prologue_octal) {
                        try self.addError(prologue_octal_span, "Octal escape sequences are not allowed in strict mode");
                    }
                } else if (self.current() == .string_literal) {
                    // directive prologue의 문자열 — octal escape 추적
                    if (self.scanner.token.has_legacy_octal and !has_prologue_octal) {
                        has_prologue_octal = true;
                        prologue_octal_span = self.currentSpan();
                    }
                } else {
                    in_directive_prologue = false;
                }
            }

            const stmt = try self.parseStatement();
            if (!stmt.isNone()) try stmts.append(self.allocator, stmt);
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }

        const end = self.currentSpan().end;

        // 표현식 컨텍스트(함수 표현식, 클래스 메서드 등)에서는 닫는 `}` 뒤의 `/`가
        // division이어야 한다. scanner.prev_token_kind를 `.r_paren`으로 설정하면
        // scanSlash()가 slashIsRegex()=false로 판단하여 division으로 토큰화한다.
        // 이 설정은 expect 내부의 advance() → scanner.next()에서 사용된다.
        if (in_expression) {
            self.scanner.prev_token_kind = .r_paren;
        }
        try self.expect(.r_curly);

        const list = try self.ast.addNodeList(stmts.items);
        return try self.ast.addNode(.{
            .tag = .block_statement,
            .span = .{ .start = start, .end = end },
            .data = .{ .list = list },
        });
    }

    // ================================================================
    // 프로그램 + Statement 파싱 — statement.zig로 위임
    // ================================================================

    const statement = @import("statement.zig");

    pub fn parse(self: *Parser) !NodeIndex {
        return statement.parse(self);
    }

    pub fn parseStatementChecked(self: *Parser, comptime is_loop_body: bool) ParseError2!NodeIndex {
        return statement.parseStatementChecked(self, is_loop_body);
    }

    pub fn parseStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseStatement(self);
    }

    pub fn parseBlockStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseBlockStatement(self);
    }

    pub fn parseExpressionStatement(self: *Parser) ParseError2!NodeIndex {
        return statement.parseExpressionStatement(self);
    }

    // ================================================================
    // Function/Class Declaration — declaration.zig로 위임
    // ================================================================

    const declaration = @import("declaration.zig");

    pub fn parseFunctionDeclaration(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionDeclaration(self);
    }

    pub fn parseAsyncStatement(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseAsyncStatement(self);
    }

    pub fn parseFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionDeclarationDefaultExport(self);
    }

    pub fn parseAsyncFunctionDeclarationDefaultExport(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseAsyncFunctionDeclarationDefaultExport(self);
    }

    pub fn parseFunctionExpression(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseFunctionExpression(self);
    }

    pub fn parseFunctionExpressionWithFlags(self: *Parser, extra_flags: u32) ParseError2!NodeIndex {
        return declaration.parseFunctionExpressionWithFlags(self, extra_flags);
    }

    pub fn parseClassDeclaration(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseClassDeclaration(self);
    }

    pub fn parseClassExpression(self: *Parser) ParseError2!NodeIndex {
        return declaration.parseClassExpression(self);
    }

    pub fn parseClassWithDecorators(self: *Parser, tag: Tag, decorators: NodeList) ParseError2!NodeIndex {
        return declaration.parseClassWithDecorators(self, tag, decorators);
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

    pub fn saveState(self: *const Parser) ScannerState {
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

    pub fn restoreState(self: *Parser, s: ScannerState) void {
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
    pub fn peekNext(self: *Parser) !PeekResult {
        const saved = self.saveState();

        try self.scanner.next();
        const result = PeekResult{
            .kind = self.scanner.token.kind,
            .has_newline_before = self.scanner.token.has_newline_before,
        };

        self.restoreState(saved);
        return result;
    }

    /// peekNext의 Kind만 반환하는 편의 함수.
    pub fn peekNextKind(self: *Parser) !Kind {
        return (try self.peekNext()).kind;
    }

    /// JSX element 모드에서 다음 토큰의 Kind를 미리 본다 (현재 토큰을 소비하지 않음).
    /// JSX children 파싱 중 '<' 다음이 '/'인지 판별할 때 사용.
    /// normal 모드에서는 '/'가 regex로 해석될 수 있으므로 JSX 전용 peek이 필요하다.
    pub fn peekNextKindJSX(self: *Parser) !Kind {
        const saved = self.saveState();
        try self.scanner.nextInsideJSXElement();
        const peek_kind = self.scanner.token.kind;
        self.restoreState(saved);
        return peek_kind;
    }

    // ================================================================
    // Import/Export — module.zig로 위임
    // ================================================================

    const module_parser = @import("module.zig");

    pub fn parseImportCallArgs(self: *Parser, start: u32) ParseError2!NodeIndex {
        return module_parser.parseImportCallArgs(self, start);
    }

    pub fn parseImportDeclaration(self: *Parser) ParseError2!NodeIndex {
        return module_parser.parseImportDeclaration(self);
    }

    pub fn parseExportDeclaration(self: *Parser) ParseError2!NodeIndex {
        return module_parser.parseExportDeclaration(self);
    }

    // ================================================================
    // Expression 파싱 — expression.zig로 위임
    // ================================================================

    const expression = @import("expression.zig");

    pub fn parseExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseExpression(self);
    }

    pub fn parseAssignmentExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseAssignmentExpression(self);
    }

    pub fn parseCallExpression(self: *Parser) ParseError2!NodeIndex {
        return expression.parseCallExpression(self);
    }

    pub fn parseIdentifierName(self: *Parser) ParseError2!NodeIndex {
        return expression.parseIdentifierName(self);
    }

    pub fn parseModuleExportName(self: *Parser) ParseError2!NodeIndex {
        return expression.parseModuleExportName(self);
    }

    pub fn parsePropertyKey(self: *Parser) ParseError2!NodeIndex {
        return expression.parsePropertyKey(self);
    }

    // ================================================================
    // Binding Pattern — binding.zig로 직접 위임
    // ================================================================

    const binding_parser = @import("binding.zig");

    pub fn parseBindingIdentifier(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseBindingIdentifier(self);
    }

    pub fn parseBindingName(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseBindingName(self);
    }

    pub fn parseSimpleIdentifier(self: *Parser) ParseError2!NodeIndex {
        return binding_parser.parseSimpleIdentifier(self);
    }

    // ================================================================
    // JSX 파싱 — jsx.zig로 위임
    // ================================================================

    pub fn parseJSXElement(self: *Parser) ParseError2!NodeIndex {
        return jsx.parseJSXElement(self);
    }

    // ================================================================
    // TypeScript 파싱 — ts.zig로 위임
    // ================================================================

    pub fn parseTsTypeAliasDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsTypeAliasDeclaration(self);
    }

    pub fn parseTsInterfaceDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsInterfaceDeclaration(self);
    }

    pub fn parseConstEnum(self: *Parser) ParseError2!NodeIndex {
        return ts.parseConstEnum(self);
    }

    pub fn parseTsEnumDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsEnumDeclaration(self);
    }

    pub fn parseTsModuleDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsModuleDeclaration(self);
    }

    pub fn parseTsDeclareStatement(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsDeclareStatement(self);
    }

    pub fn parseTsAbstractClass(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsAbstractClass(self);
    }

    pub fn parseTsNamespaceBlock(self: *Parser) ParseError2!NodeIndex {
        return ts.parseNamespaceBlock(self);
    }

    pub fn parseDecoratedStatement(self: *Parser) ParseError2!NodeIndex {
        return ts.parseDecoratedStatement(self);
    }

    pub fn parseDecorator(self: *Parser) ParseError2!NodeIndex {
        return ts.parseDecorator(self);
    }

    pub fn parseTsTypeParameterDeclaration(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTsTypeParameterDeclaration(self);
    }

    pub fn tryParseTypeAnnotation(self: *Parser) ParseError2!NodeIndex {
        return ts.tryParseTypeAnnotation(self);
    }

    /// TS `this: Type` 파라미터 스킵. 함수의 첫 번째 파라미터가 `this`이면
    /// `this` + `: Type` + 선택적 `,`를 소비하고 파라미터 리스트에 추가하지 않는다.
    /// TS this parameter: `this: Type` → 스킵 (런타임에 불필요).
    /// `this:` 패턴만 감지 — bare `this`는 일반 파라미터로 처리.
    pub fn trySkipThisParameter(self: *Parser) ParseError2!void {
        if (self.current() == .kw_this) {
            const next = try self.peekNextKind();
            if (next == .colon) {
                try self.advance(); // skip 'this'
                _ = try self.tryParseTypeAnnotation(); // skip ': Type'
                _ = try self.eat(.comma);
            }
        }
    }

    pub fn tryParseReturnType(self: *Parser) ParseError2!NodeIndex {
        return ts.tryParseReturnType(self);
    }

    pub fn parseType(self: *Parser) ParseError2!NodeIndex {
        return ts.parseType(self);
    }

    pub fn parseIndexSignature(self: *Parser, start: u32, is_readonly: bool) ParseError2!NodeIndex {
        return ts.parseIndexSignature(self, start, is_readonly);
    }

    pub fn parseTypeArguments(self: *Parser) ParseError2!NodeIndex {
        return ts.parseTypeArguments(self);
    }

    // ================================================================
    // TS Arrow Function Detection
    // ================================================================

    /// TS 모드에서 `(identifier:` 또는 `(identifier?` 패턴으로 typed arrow function 감지.
    /// 현재 토큰이 `(` 일 때 호출. 2-token lookahead로 판단.
    pub fn isTypedArrowFunction(self: *Parser) !bool {
        if (self.current() != .l_paren) return false;
        const saved = self.saveState();
        defer self.restoreState(saved);

        try self.advance(); // skip (

        // (): Type => ... — 빈 파라미터 + 리턴 타입
        if (self.current() == .r_paren) {
            try self.advance();
            // ): 이면 typed arrow (리턴 타입 어노테이션)
            return self.current() == .colon;
        }

        // (...rest: Type) => ... — rest parameter with type
        if (self.current() == .dot3) return true;

        // (identifier: 패턴 — contextual keyword(get/set/number 등)도 식별자
        // ?는 ternary와 모호하므로 : 만 감지
        if (self.current() == .identifier or self.current().isKeyword() or self.current() == .escaped_keyword) {
            try self.advance(); // skip identifier
            if (self.current() == .colon) return true;
            // (a): Type => ... — 단일 파라미터 + 리턴 타입
            if (self.current() == .r_paren) {
                try self.advance();
                return self.current() == .colon;
            }
            // (a?: Type) — optional parameter
            if (self.current() == .question) return true;
            return false;
        }

        // ({}: Type) 또는 ([]: Type) — destructuring with type
        if (self.current() == .l_curly or self.current() == .l_bracket) return true;

        return false;
    }

    /// TS typed arrow function을 직접 파싱: `(a: Type, b?: Type): ReturnType => body`
    /// save/restore로 실패 시 원래 위치로 복원할 수 있도록 호출부에서 관리.
    /// TS typed arrow function 파싱 시도. 성공하면 arrow 노드, 실패하면 null (호출부가 폴백).
    pub fn parseTypedArrowParams(self: *Parser, start: u32, is_async: bool) ParseError2!?NodeIndex {
        const saved = self.saveState();
        const errors_before = self.errors.items.len;

        try self.advance(); // skip (
        self.in_formal_parameters = true;
        try self.trySkipThisParameter();
        const scratch_top = self.saveScratch();

        while (self.current() != .r_paren and self.current() != .eof) {
            const loop_guard_pos = self.scanner.token.span.start;
            const param = try self.parseBindingIdentifier();
            try self.scratch.append(self.allocator, param);
            // rest parameter 뒤에 comma가 오면 에러: (...a,) => {}
            try self.checkRestParameterLast(param);
            if (!try self.eat(.comma)) break;
            if (try self.ensureLoopProgress(loop_guard_pos)) break;
        }

        self.in_formal_parameters = false;
        if (self.current() != .r_paren) {
            self.restoreScratch(scratch_top);
            self.errors.shrinkRetainingCapacity(errors_before);
            self.restoreState(saved);
            return null;
        }
        try self.advance(); // skip )

        // TS return type annotation: ): Type =>
        _ = try self.tryParseReturnType();

        // => 확인
        if (self.current() != .arrow or self.scanner.token.has_newline_before) {
            self.restoreScratch(scratch_top);
            self.errors.shrinkRetainingCapacity(errors_before);
            self.restoreState(saved);
            return null;
        }

        // arrow function은 항상 UniqueFormalParameters — 중복 파라미터 이름 금지.
        try self.checkDuplicateArrowFormalParams(scratch_top);

        // 파라미터 노드 리스트 생성
        const params = try self.ast.addNodeList(self.scratch.items[scratch_top..]);
        self.restoreScratch(scratch_top);
        const params_node = try self.ast.addNode(.{
            .tag = .formal_parameters,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .list = params },
        });

        try self.advance(); // skip =>
        const body = try expression.parseArrowBody(self, is_async, params_node);
        const flags: u32 = if (is_async) 0x01 else 0;
        const ae = try self.ast.addExtras(&.{ @intFromEnum(params_node), @intFromEnum(body), flags });
        return try self.ast.addNode(.{
            .tag = .arrow_function_expression,
            .span = .{ .start = start, .end = self.currentSpan().start },
            .data = .{ .extra = ae },
        });
    }
};

// ============================================================
// Tests
// ============================================================

test "Parser: empty program" {
    var scanner = try Scanner.init(std.testing.allocator, "");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
}

test "Parser: variable declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const node = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, node.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: binary expression" {
    var scanner = try Scanner.init(std.testing.allocator, "1 + 2 * 3;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: if statement" {
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { if (x) { return 1; } else { return 2; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "function add(a, b) { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: call expression" {
    var scanner = try Scanner.init(std.testing.allocator, "foo(1, 2, 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: member access" {
    var scanner = try Scanner.init(std.testing.allocator, "a.b.c;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array and object literals" {
    var scanner = try Scanner.init(std.testing.allocator, "[1, 2, 3];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: error recovery" {
    var scanner = try Scanner.init(std.testing.allocator, "@@@;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: do-while statement" {
    var scanner = try Scanner.init(std.testing.allocator, "do { x++; } while (x < 10);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-in statement" {
    var scanner = try Scanner.init(std.testing.allocator, "for (var key in obj) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: for-of statement" {
    var scanner = try Scanner.init(std.testing.allocator, "for (const item of arr) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: switch statement" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "for (;;) { }");
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
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "var x = foo(bar(1, 2), 3);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-finally" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try-catch-finally" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch (e) { bar(); } finally { cleanup(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: try without catch or finally is error" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional catch binding (ES2019)" {
    var scanner = try Scanner.init(std.testing.allocator, "try { foo(); } catch { bar(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (simple)" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = x => x + 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function (parenthesized)" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = (a, b) => a + b;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: arrow function with block body" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = (x) => { return x * 2; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in array" {
    var scanner = try Scanner.init(std.testing.allocator, "[1, ...arr, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: spread in call" {
    var scanner = try Scanner.init(std.testing.allocator, "foo(...args);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class declaration" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "class Bar extends Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with static method and property" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "const Foo = class { bar() { } };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = function(x) { return x; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const [a, b, c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: object destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const { x, y } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with default values" {
    var scanner = try Scanner.init(std.testing.allocator, "const [a = 1, b = 2] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: nested destructuring" {
    var scanner = try Scanner.init(std.testing.allocator, "const { a: { b } } = obj;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: destructuring with rest" {
    var scanner = try Scanner.init(std.testing.allocator, "const [first, ...rest] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function with destructuring params" {
    var scanner = try Scanner.init(std.testing.allocator, "function foo({ x, y }, [a, b]) { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: duplicate param in array destructuring (strict)" {
    // strict mode에서 function f(a, [a, b]) {} 는 에러: a가 두 번 바인딩됨.
    // array_pattern 안의 이름을 collectBoundNames로 수집해야 잡을 수 있음.
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [a, b]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param in object destructuring (strict)" {
    // strict mode에서 function f(a, {a}) {} 는 에러: a가 두 번 바인딩됨.
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, {a}) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: no duplicate in different destructuring names (strict)" {
    // 이름이 다르면 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [b, c]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: duplicate param nested destructuring (strict)" {
    // 중첩 destructuring: function f(a, [{a}]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [{a}]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param with default value in array (strict)" {
    // default value: function f(a, [a = 1]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [a = 1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param with rest in array (strict)" {
    // rest element: function f(a, [...a]) {} → a가 중복
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; function f(a, [...a]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: duplicate param within same destructuring (generator)" {
    // generator 함수에서도 destructuring 내 중복은 에러
    // function* f([a, a]) {} → a가 중복 (generator는 항상 중복 검사)
    var scanner = try Scanner.init(std.testing.allocator, "function* f([a, a]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

// ============================================================
// Import / Export tests
// ============================================================

test "Parser: import side-effect" {
    var scanner = try Scanner.init(std.testing.allocator, "import 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default" {
    var scanner = try Scanner.init(std.testing.allocator, "import foo from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import named" {
    var scanner = try Scanner.init(std.testing.allocator, "import { a, b as c } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import namespace" {
    var scanner = try Scanner.init(std.testing.allocator, "import * as ns from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import default + named" {
    var scanner = try Scanner.init(std.testing.allocator, "import React, { useState } from 'react';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default" {
    var scanner = try Scanner.init(std.testing.allocator, "export default 42;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named" {
    var scanner = try Scanner.init(std.testing.allocator, "export { a, b as c };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "export const x = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export all re-export" {
    var scanner = try Scanner.init(std.testing.allocator, "export * from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export named re-export" {
    var scanner = try Scanner.init(std.testing.allocator, "export { foo } from 'module';");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: export default function" {
    var scanner = try Scanner.init(std.testing.allocator, "export default function foo() { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: dynamic import expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const m = import('module');");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async function declaration" {
    var scanner = try Scanner.init(std.testing.allocator, "async function fetchData() { return await fetch(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: generator function" {
    var scanner = try Scanner.init(std.testing.allocator, "function* gen() { yield 1; yield 2; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: yield delegate" {
    var scanner = try Scanner.init(std.testing.allocator, "function* gen() { yield* other(); }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: async arrow function" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = async () => { await fetch(); };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with private field and method" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "this.#name;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (array)" {
    // 배열 대입 구조분해 — 현재 array_expression + assignment로 파싱됨
    // semantic analysis에서 assignment target으로 변환 예정
    var scanner = try Scanner.init(std.testing.allocator, "[a, b] = [1, 2];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: assignment destructuring (object)" {
    var scanner = try Scanner.init(std.testing.allocator, "({ x, y } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import.meta" {
    var scanner = try Scanner.init(std.testing.allocator, "const url = import.meta.url;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: array elision [, , x]" {
    var scanner = try Scanner.init(std.testing.allocator, "const [, , x] = arr;");
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
    var scanner = try Scanner.init(std.testing.allocator, "const x: number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS function with typed params and return" {
    var scanner = try Scanner.init(std.testing.allocator, "function add(a: number, b: number): number { return a + b; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS union type" {
    var scanner = try Scanner.init(std.testing.allocator, "const x: string | number = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS array type" {
    var scanner = try Scanner.init(std.testing.allocator, "const arr: number[] = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type" {
    var scanner = try Scanner.init(std.testing.allocator, "const arr: Array<string> = [];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS as expression" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = value as string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS non-null assertion" {
    var scanner = try Scanner.init(std.testing.allocator, "const x = value!;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS object type literal" {
    var scanner = try Scanner.init(std.testing.allocator, "const obj: { x: number; y: string } = { x: 1, y: 'a' };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS tuple type" {
    var scanner = try Scanner.init(std.testing.allocator, "const t: [string, number] = ['a', 1];");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS typeof and keyof" {
    var scanner = try Scanner.init(std.testing.allocator, "const k: keyof typeof obj = 'x';");
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
    var scanner = try Scanner.init(std.testing.allocator, "type StringOrNumber = string | number;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type alias" {
    var scanner = try Scanner.init(std.testing.allocator, "type Result<T, E> = { ok: T } | { err: E };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS interface" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    // interface Admin extends User — 단일 extends를 NodeList(len=1)로 저장
    var scanner = try Scanner.init(std.testing.allocator, "interface Admin extends User { role: string; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // program.data.list → interface 노드 접근
    const program = parser.ast.getNode(root);
    try std.testing.expectEqual(Tag.program, program.tag);
    // program body의 첫 번째 stmt = ts_interface_declaration
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);
    // extra = [name, type_params, extends_start, extends_len, body]
    // extends User → extends_len = 1
    const extends_len = parser.ast.extra_data.items[iface.data.extra + 3];
    try std.testing.expectEqual(@as(u32, 1), extends_len);
}

test "Parser: TS interface multiple extends" {
    // interface Foo extends Bar, Baz — 다중 extends를 NodeList로 정확히 저장
    var scanner = try Scanner.init(std.testing.allocator, "interface Foo extends Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    const program = parser.ast.getNode(root);
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);

    // extra = [name, type_params, extends_start, extends_len, body]
    const e = iface.data.extra;
    const extends_start = parser.ast.extra_data.items[e + 2];
    const extends_len = parser.ast.extra_data.items[e + 3];
    // extends Bar, Baz → 2개
    try std.testing.expectEqual(@as(u32, 2), extends_len);

    // 두 extends 노드가 유효한 타입 노드인지 확인
    const bar = parser.ast.getNode(@enumFromInt(parser.ast.extra_data.items[extends_start]));
    const baz = parser.ast.getNode(@enumFromInt(parser.ast.extra_data.items[extends_start + 1]));
    try std.testing.expect(bar.tag != .invalid);
    try std.testing.expect(baz.tag != .invalid);
}

test "Parser: TS interface no extends" {
    // extends 없는 경우 extends_len = 0
    var scanner = try Scanner.init(std.testing.allocator, "interface Empty { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    const root = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    const program = parser.ast.getNode(root);
    const iface_raw = parser.ast.extra_data.items[program.data.list.start];
    const iface = parser.ast.getNode(@enumFromInt(iface_raw));
    try std.testing.expectEqual(Tag.ts_interface_declaration, iface.tag);

    // extends 없으면 extends_len = 0
    const extends_len = parser.ast.extra_data.items[iface.data.extra + 3];
    try std.testing.expectEqual(@as(u32, 0), extends_len);
}

test "Parser: TS enum" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "namespace Utils { const x = 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS declare" {
    var scanner = try Scanner.init(std.testing.allocator, "declare const VERSION: string;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS abstract class" {
    var scanner = try Scanner.init(std.testing.allocator, "abstract class Shape { abstract area(): number; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS generic type parameter with constraint and default" {
    var scanner = try Scanner.init(std.testing.allocator, "type Foo<T extends string = 'hello'> = T;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: TS parameter property" {
    var scanner = try Scanner.init(std.testing.allocator, "class Foo { constructor(public x: number, private y: string) { } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class" {
    var scanner = try Scanner.init(std.testing.allocator, "@Component class Foo { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator with arguments" {
    var scanner = try Scanner.init(std.testing.allocator, "@Injectable() class Service { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: decorator on class member" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "class Foo implements Bar, Baz { }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: static readonly member" {
    var scanner = try Scanner.init(std.testing.allocator, "class Foo { static readonly MAX = 100; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: class with generics" {
    var scanner = try Scanner.init(std.testing.allocator, "class Box<T> { value: T; }");
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
    var scanner = try Scanner.init(std.testing.allocator, "const x = <br />;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX element with children" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <div>hello</div>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with attributes" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <div className="foo" id="bar" />;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: JSX with expression" {
    var scanner = try Scanner.init(std.testing.allocator,
        \\const x = <span>{name}</span>;
    );
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_jsx = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: function call with division in args" {
    // arrow lookahead가 prev_token_kind를 복구하지 않으면
    // / 가 regex로 해석되어 실패하던 버그 테스트
    const source = "truncate(x / y)";
    var scanner = try Scanner.init(std.testing.allocator, source);
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
    var scanner = try Scanner.init(std.testing.allocator, "return 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: return inside function is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "function f() { return 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: return inside arrow function is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "const f = () => { return 1; };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break outside loop/switch is error" {
    var scanner = try Scanner.init(std.testing.allocator, "break;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: break inside loop is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "while (true) { break; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break inside switch is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "function f(x) { switch (x) { case 1: break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: continue outside loop is error" {
    var scanner = try Scanner.init(std.testing.allocator, "continue;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'continue' outside of loop", parser.errors.items[0].message);
}

test "Parser: continue inside for loop is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "for (var i = 0; i < 10; i++) { continue; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: break in nested function inside loop is error" {
    // 함수 경계에서 loop 컨텍스트가 리셋되므로, 내부 함수의 break는 에러
    var scanner = try Scanner.init(std.testing.allocator, "while (true) { function f() { break; } }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqualStrings("'break' outside of loop or switch", parser.errors.items[0].message);
}

test "Parser: with statement in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "with (obj) { x; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: use strict in function body" {
    // 함수 내부 "use strict"가 strict mode를 설정하는지 확인
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "with (obj) { x; }");
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
    var scanner = try Scanner.init(std.testing.allocator, "var var = 123;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: strict mode reserved word as binding in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator,
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
    var scanner = try Scanner.init(std.testing.allocator, "var implements = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: let as variable name is valid in non-strict" {
    var scanner = try Scanner.init(std.testing.allocator, "var let = 1;");
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
    var scanner = try Scanner.init(std.testing.allocator, "++this;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: delete identifier in strict mode is error" {
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; delete x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: const without initializer is error" {
    var scanner = try Scanner.init(std.testing.allocator, "const x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: for-of const without init is valid" {
    var scanner = try Scanner.init(std.testing.allocator, "for (const x of [1]) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: import/export only at module top-level" {
    // import in function body — error even in module
    var scanner = try Scanner.init(std.testing.allocator, "function f() { import 'x'; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: function in loop body is error" {
    var scanner = try Scanner.init(std.testing.allocator, "for (;;) function f() {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: yield is identifier outside generator" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is identifier in script mode" {
    var scanner = try Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "Parser: await is reserved in module mode" {
    var scanner = try Scanner.init(std.testing.allocator, "var await = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    parser.is_module = true;
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: super outside method is error" {
    var scanner = try Scanner.init(std.testing.allocator, "super.x;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: new.target outside function is error" {
    var scanner = try Scanner.init(std.testing.allocator, "new.target;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: object shorthand reserved word is error" {
    var scanner = try Scanner.init(std.testing.allocator, "({true});");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: optional chaining is not assignment target" {
    var scanner = try Scanner.init(std.testing.allocator, "x?.y = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: parenthesized destructuring is not assignment target" {
    var scanner = try Scanner.init(std.testing.allocator, "({}) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "Parser: arguments in class field initializer is error" {
    // class field에서 arguments 직접 사용 — SyntaxError
    {
        var scanner = try Scanner.init(std.testing.allocator, "var C = class { x = arguments; };");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // arrow function 안에서 arguments 사용 — arrow는 자체 arguments가 없으므로 SyntaxError
    {
        var scanner = try Scanner.init(std.testing.allocator, "class C { x = () => arguments; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len > 0);
    }
    // 일반 function 안에서 arguments 사용 — 자체 arguments 바인딩이 있으므로 OK
    {
        var scanner = try Scanner.init(std.testing.allocator, "class C { x = function() { return arguments; }; }");
        defer scanner.deinit();
        var parser = Parser.init(std.testing.allocator, &scanner);
        defer parser.deinit();

        _ = try parser.parse();
        try std.testing.expect(parser.errors.items.len == 0);
    }
}

// ============================================================
// Cover Grammar 유닛 테스트
// ============================================================

test "CoverGrammar: rest element with initializer in array destructuring" {
    // [...x = 1] = arr → rest에 initializer 금지
    var scanner = try Scanner.init(std.testing.allocator, "[...x = 1] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    // "rest element may not have a default initializer" 에러가 포함되어야 함
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: valid array destructuring" {
    // [a, b, ...c] = arr → 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "[a, b, ...c] = arr;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: valid object destructuring" {
    // ({ a, b: c } = obj) → 에러 없음
    var scanner = try Scanner.init(std.testing.allocator, "({ a, b: c } = obj);");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);
}

test "CoverGrammar: strict mode eval assignment" {
    // "use strict"; eval = 1 → 에러
    var scanner = try Scanner.init(std.testing.allocator, "\"use strict\"; eval = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: parenthesized destructuring is invalid" {
    // ([x]) = 1 → parenthesized destructuring 금지
    var scanner = try Scanner.init(std.testing.allocator, "([x]) = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: for-in with rest-init is error" {
    // for ([...x = 1] in obj) {} → rest-init 금지
    var scanner = try Scanner.init(std.testing.allocator, "for ([...x = 1] in obj) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "CoverGrammar: arrow params rest-init is error" {
    // ([...x = 1]) => {} → rest-init 금지
    var scanner = try Scanner.init(std.testing.allocator, "([...x = 1]) => {};");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    var found = false;
    for (parser.errors.items) |err| {
        if (std.mem.indexOf(u8, err.message, "rest element") != null) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

// ================================================================
// 에러 메시지 품질 회귀 테스트
// oxc/swc 수준의 친절한 에러 메시지가 유지되는지 검증한다.
// ================================================================

/// 테스트 헬퍼: 특정 message를 가진 에러가 있는지 확인한다.
/// 추가로 found, related_label, hint 필드를 검증할 수 있다.
const ErrorCheck = struct {
    /// 에러 message (정확 일치)
    message: ?[]const u8 = null,
    /// 에러 message (부분 일치)
    message_contains: ?[]const u8 = null,
    /// found 필드가 non-null이어야 하는지
    has_found: ?bool = null,
    /// related_span이 non-null이어야 하는지
    has_related_span: ?bool = null,
    /// related_label 기대값 (정확 일치)
    related_label: ?[]const u8 = null,
    /// hint가 non-null이어야 하는지
    has_hint: ?bool = null,
    /// hint 기대값 (정확 일치)
    hint: ?[]const u8 = null,
};

/// 테스트 헬퍼: 소스를 파싱하고 조건에 맞는 에러가 있는지 검증한다.
fn expectParseError(source: []const u8, check: ErrorCheck) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);

    for (parser.errors.items) |err| {
        const msg_match = if (check.message) |m| std.mem.eql(u8, err.message, m) else true;
        const contains_match = if (check.message_contains) |c| std.mem.indexOf(u8, err.message, c) != null else true;
        if (!msg_match or !contains_match) continue;

        // message 매칭된 에러를 찾음 — 나머지 필드 검증
        if (check.has_found) |hf| try std.testing.expectEqual(hf, err.found != null);
        if (check.has_related_span) |hr| try std.testing.expectEqual(hr, err.related_span != null);
        if (check.related_label) |rl| {
            try std.testing.expect(err.related_label != null);
            try std.testing.expectEqualStrings(rl, err.related_label.?);
        }
        if (check.has_hint) |hh| try std.testing.expectEqual(hh, err.hint != null);
        if (check.hint) |h| {
            try std.testing.expect(err.hint != null);
            try std.testing.expectEqualStrings(h, err.hint.?);
        }
        return; // 검증 성공
    }
    // 매칭되는 에러를 못 찾음
    return error.TestUnexpectedResult;
}

/// 테스트 헬퍼: 소스를 파싱하고 에러가 없는지 검증한다.
fn expectNoParseError(source: []const u8) !void {
    var scanner = try Scanner.init(std.testing.allocator, source);
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "ErrorMsg: expect() shows 'found' token" {
    // `if (true]` → Expected ')' but found ']'
    try expectParseError("if (true]", .{ .message = ")", .has_found = true });
}

test "ErrorMsg: expect() shows found for curly brace" {
    // `if (true) {` → EOF에서 '}' 기대
    try expectParseError("if (true) {", .{ .message = "}", .has_found = true });
}

test "ErrorMsg: bracket matching shows related_span for paren" {
    // `function f(a, b ]` → Expected ')' but found ']', opening '(' is here
    try expectParseError("function f(a, b ]", .{
        .message = ")",
        .has_related_span = true,
        .related_label = "opening '(' is here",
    });
}

test "ErrorMsg: bracket matching shows related_span for curly" {
    // `if (true) { var x = 1;` → EOF에서 '}' 기대, opening '{' is here
    try expectParseError("if (true) { var x = 1;", .{
        .message = "}",
        .has_related_span = true,
        .related_label = "opening '{' is here",
    });
}

test "ErrorMsg: bracket matching shows related_span for bracket" {
    // `var a = [1, 2` → EOF에서 ']' 기대, opening '[' is here
    try expectParseError("var a = [1, 2", .{
        .message = "]",
        .has_related_span = true,
        .related_label = "opening '[' is here",
    });
}

test "ErrorMsg: expectSemicolon shows found and hint" {
    // `var x = 1 var y = 2` → Expected ';' but found 'var', hint: Try inserting...
    try expectParseError("var x = 1 var y = 2", .{
        .message = ";",
        .has_found = true,
        .hint = "Try inserting a semicolon here",
    });
}

test "ErrorMsg: ASI still works with newline (no false error)" {
    try expectNoParseError("var x = 1\nvar y = 2");
}

test "ErrorMsg: ASI still works with closing curly (no false error)" {
    try expectNoParseError("function f() { return 1 }");
}

test "ErrorMsg: addError backward compat (no found/hint)" {
    // 기존 addError로 추가된 에러는 found, hint가 null
    try expectParseError("'use strict'; with (obj) {}", .{
        .message_contains = "with",
        .has_found = false,
        .has_hint = false,
    });
}

test "ErrorMsg: multiple errors all have proper fields" {
    var scanner = try Scanner.init(std.testing.allocator, "function( { ) }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    for (parser.errors.items) |err| {
        try std.testing.expect(err.message.len > 0);
    }
}

test "ErrorMsg: nested brackets track correctly" {
    // 중첩 괄호: `if ([1, (2` → 에러에 related_span이 하나 이상 존재
    var scanner = try Scanner.init(std.testing.allocator, "if ([1, (2");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    var has_related = false;
    for (parser.errors.items) |err| {
        if (err.related_span != null) {
            has_related = true;
            break;
        }
    }
    try std.testing.expect(has_related);
}

test "ErrorMsg: valid code has no errors (regression)" {
    // 정상 코드는 에러가 없어야 함 — 새 기능이 false positive를 만들지 않는지
    const cases = [_][]const u8{
        "const x = [1, 2, 3];",
        "function f(a, b) { return a + b; }",
        "if (true) { console.log('yes'); } else { console.log('no'); }",
        "for (let i = 0; i < 10; i++) { }",
        "const obj = { a: 1, b: [2, 3], c: { d: 4 } };",
        "class Foo { constructor() { this.x = 1; } }",
        "const arrow = (x) => x * 2;",
        "try { throw new Error(); } catch (e) { } finally { }",
        "switch (x) { case 1: break; default: break; }",
    };
    for (cases) |src| {
        try expectNoParseError(src);
    }
}

// ================================================================
// Diagnostic 통합 + 예약어 검증 테스트
// ================================================================

test "Diagnostic: parser errors have kind=parse" {
    var scanner = try Scanner.init(std.testing.allocator, "var 123bad;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
    try std.testing.expectEqual(Diagnostic.Kind.parse, parser.errors.items[0].kind);
}

test "ReservedWord: escaped keyword in variable binding is error" {
    // \u0066or → "for" (reserved keyword)
    try expectParseError("var \\u0066or = 1;", .{
        .message_contains = "Escape",
    });
}

test "ReservedWord: escaped strict reserved in strict mode binding is error" {
    // \u006Cet → "let" (strict mode reserved)
    try expectParseError("'use strict'; var \\u006Cet = 1;", .{
        .message_contains = "Escape",
    });
}

test "ReservedWord: escaped strict reserved in sloppy mode is OK" {
    // escaped strict reserved in sloppy mode → allowed
    try expectNoParseError("var \\u006Cet = 1;");
}

test "ReservedWord: escaped eval in strict mode assignment is error" {
    // \u0065val → "eval" — strict mode에서 assignment target 불가
    try expectParseError("'use strict'; \\u0065val = 1;", .{
        .message_contains = "eval",
    });
}

test "ReservedWord: property name can use escaped keyword" {
    // property name에서는 escaped keyword 허용 (ECMAScript IdentifierName)
    try expectNoParseError("var obj = { \\u0066or: 1 };");
}

test "ReservedWord: escaped keyword as property access is OK" {
    // member expression에서 escaped keyword는 허용
    try expectNoParseError("obj.\\u0066or;");
}

// ============================================================
// TS Arrow Function with Type Annotations (#286)
// ============================================================

test "TS arrow: basic typed params" {
    try expectNoParseError("const add = (a: number, b: number) => a + b;");
}

test "TS arrow: return type annotation" {
    try expectNoParseError("const f = (x: string): string => x.toUpperCase();");
}

test "TS arrow: optional param" {
    try expectNoParseError("const g = (a: number, b?: string) => a;");
}

test "TS arrow: destructuring with type" {
    try expectNoParseError("const f = ({x}: {x: number}) => x;");
}

test "TS arrow: rest param with type" {
    try expectNoParseError("const f = (...args: number[]) => args;");
}

test "TS arrow: async with types" {
    try expectNoParseError("const f = async (a: number): Promise<number> => a;");
}

test "TS arrow: empty params with return type" {
    try expectNoParseError("const f = (): void => {};");
}

test "TS arrow: contextual keyword as param name (get/set/number)" {
    // contextual keyword는 import default specifier와 arrow param 모두에서 식별자로 유효
    try expectNoParseError("const f = (get: number) => get;");
    try expectNoParseError("const f = (set: string) => set;");
    try expectNoParseError("const f = (number: number) => number;");
    try expectNoParseError("const f = (string: string) => string;");
    try expectNoParseError("const f = (object: any) => object;");
}

test "TS arrow: non-arrow parenthesized expression still works" {
    // TS arrow가 아닌 일반 괄호 표현식 — 기존 동작 유지
    try expectNoParseError("const x = (1 + 2) * 3;");
    try expectNoParseError("const x = (a);");
    try expectNoParseError("const x = (a, b);");
}

test "TS arrow: plain JS arrow still works" {
    try expectNoParseError("const f = (x, y) => x + y;");
    try expectNoParseError("const f = x => x;");
    try expectNoParseError("const f = () => 42;");
}

// ============================================================
// TS arrow function edge cases
// ============================================================

test "TS arrow: default value with type" {
    try expectNoParseError("const f = (x: number = 10) => x;");
}

test "TS arrow: nested arrow with types" {
    try expectNoParseError("const f = (x: number) => (y: string) => x + y;");
}

test "TS arrow: trailing comma" {
    try expectNoParseError("const f = (a: number, b: string,) => a;");
}

test "TS arrow: complex union type param" {
    try expectNoParseError("const f = (x: string | number) => x;");
}

test "TS arrow: IIFE with types" {
    try expectNoParseError("((a: number) => a + 1)(5);");
}

test "TS arrow: return type object literal" {
    try expectNoParseError("const f = (x: number): {a: number} => ({a: x});");
}

// ============================================================
// Contextual keyword binding edge cases
// ============================================================

test "binding: type/from/of/as/async as function params" {
    try expectNoParseError("function f(type, from, of, as) { return type + from + of + as; }");
    try expectNoParseError("function f(async) { return async; }");
}

test "binding: nested destructuring with defaults" {
    try expectNoParseError("const { a = 1, b = 2 } = {};");
    try expectNoParseError("const { a: { b } } = { a: { b: 1 } };");
    try expectNoParseError("const [a, , b] = [1, 2, 3];");
}

test "binding: contextual keyword as catch param" {
    try expectNoParseError("try {} catch (type) { console.log(type); }");
    try expectNoParseError("try {} catch (from) { console.log(from); }");
}

test "binding: contextual keyword as for-of variable" {
    // contextual keywords as for-of binding
    try expectNoParseError("for (const type of [1,2,3]) { console.log(type); }");
    try expectNoParseError("for (const get of [1,2,3]) { console.log(get); }");
}

// ============================================================
// static_member_expression span 테스트
// ============================================================

test "Parser: static_member_expression span excludes trailing whitespace" {
    // "a.b ;" — span은 0..3 ("a.b"), 공백과 세미콜론 포함 안 함
    var scanner = try Scanner.init(std.testing.allocator, "a.b ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // AST에서 static_member_expression 노드를 찾아 span 검증
    var found = false;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            // span.start == 0 ("a"의 시작), span.end == 3 ("b"의 끝)
            try std.testing.expectEqual(@as(u32, 0), node.span.start);
            try std.testing.expectEqual(@as(u32, 3), node.span.end);
            // 소스 텍스트로도 검증
            try std.testing.expectEqualStrings("a.b", parser.ast.source[node.span.start..node.span.end]);
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

test "Parser: chained static_member_expression span" {
    // "a.b.c ;" — 외부 static_member_expression의 span은 0..5 ("a.b.c")
    var scanner = try Scanner.init(std.testing.allocator, "a.b.c ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // 체인이므로 static_member_expression이 2개 있어야 함:
    //   내부: a.b (0..3), 외부: a.b.c (0..5)
    var count: usize = 0;
    var has_inner = false;
    var has_outer = false;
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            count += 1;
            const text = parser.ast.source[node.span.start..node.span.end];
            if (std.mem.eql(u8, text, "a.b")) has_inner = true;
            if (std.mem.eql(u8, text, "a.b.c")) has_outer = true;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(has_inner);
    try std.testing.expect(has_outer);
}

test "Parser: static_member_expression text matches source exactly" {
    // "process.env.NODE_ENV ;" 에서
    // source[span.start..span.end] == "process.env.NODE_ENV" (공백 없이)
    var scanner = try Scanner.init(std.testing.allocator, "process.env.NODE_ENV ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();

    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len == 0);

    // 가장 바깥 static_member_expression (span이 가장 넓은 것)의 텍스트를 검증
    var max_span_len: u32 = 0;
    var max_span_text: []const u8 = "";
    for (parser.ast.nodes.items) |node| {
        if (node.tag == .static_member_expression) {
            const len = node.span.end - node.span.start;
            if (len > max_span_len) {
                max_span_len = len;
                max_span_text = parser.ast.source[node.span.start..node.span.end];
            }
        }
    }
    // define 매칭에 사용되는 getNodeText가 정확한 텍스트를 반환하는지 검증
    // 공백이 포함되지 않아야 함
    try std.testing.expectEqualStrings("process.env.NODE_ENV", max_span_text);
}

// ============================================================
// Destructuring default values in arrow params (cover grammar)
// ============================================================

test "CoverGrammar: arrow param destructuring with boolean defaults" {
    // { x = false, y = false } — false/true/null은 default value이지 param name이 아님
    try expectNoParseError("const f = (s, { x = false, y = false } = {}) => s;");
    try expectNoParseError("const f = (s, { x = true, y = true } = {}) => s;");
    try expectNoParseError("const f = (s, { x = null, y = null } = {}) => s;");
}

test "CoverGrammar: arrow param destructuring with identifier defaults" {
    // { x = a, y = a } — a는 default value 참조이지 param name이 아님
    try expectNoParseError("const f = (s, { x = a, y = a } = {}) => s;");
    try expectNoParseError("const f = ({ x = foo, y = foo } = {}) => s;");
}

test "CoverGrammar: arrow param destructuring with number defaults" {
    try expectNoParseError("const f = (s, { x = 1, y = 2 } = {}) => s;");
}

test "CoverGrammar: actual duplicate param names are still detected" {
    // 실제 중복 파라미터는 에러가 나야 함
    try expectParseError("const f = (x, { x } = {}) => s;", .{ .message = "Duplicate parameter name" });
}

test "CoverGrammar: arrow param single destructuring with defaults" {
    // 단일 파라미터 (sequence가 아닌 경우)
    try expectNoParseError("const f = ({ x = false, y = false } = {}) => s;");
    try expectNoParseError("const f = ({ x = false, y = false }) => s;");
}

test "CoverGrammar: literal keywords parsed as boolean_literal not identifier" {
    // true/false/null이 expression 위치에서 올바른 리터럴 노드로 파싱되는지 검증
    try expectNoParseError("const a = true;");
    try expectNoParseError("const b = false;");
    try expectNoParseError("const c = null;");
    try expectNoParseError("const obj = { true: 1, false: 2, null: 3 };");
}

// ================================================================
// 제네릭 토큰 분할 테스트 (>> → > + >, >= → > + = 등)
// ================================================================

test "TokenSplit: nested generic >> splits to > + >" {
    // Array<Array<number>> — >> 가 > > 로 분할되어야 함
    try expectNoParseError("let x: Array<Array<number>>");
}

test "TokenSplit: triple nested generic >>> splits correctly" {
    // A<B<C<number>>> — >>> 가 > > > 로 분할
    try expectNoParseError("let x: A<B<C<number>>>");
}

test "TokenSplit: >= splits to > + = in arrow return type" {
    // (): A<T>=> 0 — >= 가 > = 로 분할, arrow function으로 파싱
    try expectNoParseError("(): A<T>=> 0");
}

test "TokenSplit: nested generic in return type" {
    try expectNoParseError("let x: () => A<B<T>>");
}

test "TokenSplit: type assertion with nested generic" {
    // <Array<number>>expr — >> 분할 후 type assertion
    try expectNoParseError("let x = <Array<number>>y");
}

test "TokenSplit: generic type arguments with nested generics" {
    try expectNoParseError("type Foo = Map<string, Array<number>>");
    try expectNoParseError("type Bar = Promise<Map<string, Set<number>>>");
}

test "TokenSplit: generic function return type with nested generic" {
    try expectNoParseError("function foo(): Array<Array<number>> { return []; }");
}

test "TokenSplit: interface with nested generic members" {
    try expectNoParseError("interface Foo { bar: Map<string, Array<number>> }");
}

test "TokenSplit: type alias with conditional + nested generic" {
    try expectNoParseError("type Foo<T> = T extends Array<Array<number>> ? T : never");
}

// === yield identifier validation tests ===

test "yield: identifier in generator body should error" {
    // `void yield` in generator — yield is IdentifierReference, not YieldExpression
    // ECMAScript: IdentifierReference[Yield] cannot be "yield"
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { void yield; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    // Should have at least one error about yield
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "yield;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in sloppy mode should be fine" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "yield: expression in generator should be fine" {
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { yield 1; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "yield: destructuring in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "for ([ x = yield ] of [[]]) ;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: as parameter name in generator should error" {
    // yield as parameter name in generator is forbidden
    var scanner = try Scanner.init(std.testing.allocator, "function *gen(yield) {}");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: in module code should error" {
    // module code is always strict, so yield as identifier is forbidden
    var scanner = try Scanner.init(std.testing.allocator, "var x = yield;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;
    parser.is_strict_mode = true; // module is always strict
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: typeof yield in generator should error" {
    var scanner = try Scanner.init(std.testing.allocator, "function *gen() { typeof yield; }");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "yield: as variable name in strict mode should error" {
    var scanner = try Scanner.init(std.testing.allocator, "var yield = 1;");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_strict_mode = true;
    _ = try parser.parse();
    try std.testing.expect(parser.errors.items.len > 0);
}

test "CoverGrammar: arrow destructuring duplicate params" {
    try expectParseError("([x, x]) => 1", .{ .message = "Duplicate parameter name" });
}

test "CoverGrammar: arrow destructuring duplicate params - object" {
    try expectParseError("({y: x, x}) => 1", .{ .message = "Duplicate parameter name" });
    try expectParseError("({a: x, b: x}) => 1", .{ .message = "Duplicate parameter name" });
    try expectParseError("({x, ...x}) => 1", .{ .message = "Duplicate parameter name" });
}

test "rest params trailing comma: arrow" {
    try expectParseError("(...a,) => {}", .{ .message_contains = "Rest parameter must be last formal parameter" });
}

test "rest params trailing comma: async arrow" {
    try expectParseError("async (...a,) => {}", .{ .message_contains = "Rest parameter must be last formal parameter" });
}

// === using / await using declaration tests ===

test "using declaration: basic" {
    try expectNoParseError("{ using x = getResource(); }");
}

test "using as identifier: assignment" {
    try expectNoParseError("using = 1;");
}

test "using as identifier: var declaration" {
    try expectNoParseError("var using = 1;");
}

test "using as identifier: function name" {
    try expectNoParseError("function using() {}");
}

test "await using in module top-level" {
    // module top-level에서 await using은 허용 (top-level await)
    var scanner = try Scanner.init(std.testing.allocator, "await using x = { };");
    defer scanner.deinit();
    var parser = Parser.init(std.testing.allocator, &scanner);
    defer parser.deinit();
    parser.is_module = true;
    scanner.is_module = true;

    _ = try parser.parse();
    try std.testing.expectEqual(@as(usize, 0), parser.errors.items.len);
}

test "await using in async function" {
    try expectNoParseError("async function f() { await using x = getResource(); }");
}

// === accessor as identifier tests ===

test "accessor as identifier: var declaration" {
    try expectNoParseError("var accessor;");
}

test "accessor as identifier: let declaration" {
    try expectNoParseError("let accessor;");
}

test "accessor as identifier: const declaration" {
    try expectNoParseError("const accessor = null;");
}

test "accessor as identifier: function name" {
    try expectNoParseError("function accessor() {}");
}

test "accessor as identifier: function parameter" {
    try expectNoParseError("function foo(accessor) {}");
}

test "accessor as identifier: assignment" {
    try expectNoParseError("var accessor; accessor = 1;");
}

test "accessor as class field name" {
    // accessor;  accessor = 42;  accessor() {} — 일반 멤버 이름으로 사용
    try expectNoParseError("class C { accessor; }");
    try expectNoParseError("class C { accessor = 42; }");
    try expectNoParseError("class C { accessor() { return 42; } }");
}

test "accessor with newline in class body" {
    // accessor 뒤에 줄바꿈이 있으면 ASI → accessor는 필드 이름
    try expectNoParseError(
        \\class C {
        \\  accessor
        \\  a = 42;
        \\}
    );
}

test "accessor static with newline in class body" {
    // static accessor\n static a = 42; → accessor는 필드 이름
    try expectNoParseError(
        \\class C {
        \\  static accessor
        \\  static a = 42;
        \\}
    );
}
