//! ECMAScript 정규식 패턴 파서.
//!
//! `/pattern/flags` 의 pattern 부분을 검증한다.
//! comptime emit_ast=false이면 검증만, true이면 AST 빌드.
//!
//! ECMAScript 정규식 문법 (간략):
//!   Pattern     -> Disjunction
//!   Disjunction -> Alternative ('|' Alternative)*
//!   Alternative -> Term*
//!   Term        -> Assertion | Atom Quantifier?
//!   Atom        -> '.' | CharacterClass | Group | Escape | Character
//!
//! 참고: references/oxc/crates/oxc_regular_expression/src/parser

const std = @import("std");
const flags_mod = @import("flags.zig");
const Flags = flags_mod.Flags;

/// AST 타입.
pub const ast = @import("ast.zig");

/// 유니코드 프로퍼티 검증 테이블.
pub const unicode_property = @import("unicode_property.zig");

/// 패턴 파서. comptime emit_ast로 검증/AST 모드 분리.
///
/// - emit_ast=false: 검증만 수행, 할당 없음 (현재 렉서에서 사용)
/// - emit_ast=true: AST를 빌드하여 반환, allocator 필요
pub fn PatternParser(comptime emit_ast: bool) type {
    return struct {
        const Self = @This();

        /// 패턴 소스 텍스트
        source: []const u8,
        /// 현재 위치
        pos: u32 = 0,
        /// 파싱된 플래그 (unicode mode 판별에 필요)
        flags: Flags,
        /// 에러 메시지 (첫 번째 에러만)
        err_message: ?[]const u8 = null,
        /// 에러 위치
        err_offset: u32 = 0,
        /// capturing group 카운트 (back reference 검증용)
        group_count: u32 = 0,
        /// named group 이름 목록 (중복 검증용)
        named_groups: [32][]const u8 = undefined,
        named_group_count: u8 = 0,
        /// 가장 큰 back reference 번호 (group_count와 비교)
        max_back_ref: u32 = 0,
        /// named back reference 이름 목록 (파싱 끝에서 존재 검증)
        named_refs: [32][]const u8 = undefined,
        named_ref_count: u8 = 0,

        // ── character class range 검증용 ──
        // parseClassAtom/parseEscape가 설정, parseCharacterClass에서 사용.

        /// 마지막 class atom의 codepoint 값 (range 순서 검증용).
        last_class_value: u32 = 0,
        /// 마지막 class atom이 \d, \D, \w, \W, \s, \S인지 (range endpoint 금지).
        last_class_is_class_escape: bool = false,
        /// v-flag class의 contents kind (parseClassSetExpression이 설정).
        last_class_contents_kind: ast.CharacterClassContentsKind = .@"union",

        // ── AST 모드 전용 필드 ──
        // emit_ast=false일 때는 void 타입 (0바이트, 메모리 사용 없음)

        /// AST 노드 flat 배열.
        ast_nodes: if (emit_ast) std.ArrayList(ast.Node) else void =
            if (emit_ast) undefined else {},
        /// 가변 길이 자식 리스트 데이터.
        ast_extra: if (emit_ast) std.ArrayList(u32) else void =
            if (emit_ast) undefined else {},
        /// 마지막으로 빌드한 AST 노드. parse 함수들이 결과를 전달하는 데 사용.
        last_node: if (emit_ast) ast.NodeIndex else void =
            if (emit_ast) .none else {},

        // ================================================================
        // 초기화 / 공개 API
        // ================================================================

        /// 검증 전용 초기화 (emit_ast=false).
        /// emit_ast=true에서는 initWithAllocator()를 사용해야 한다.
        pub fn init(source: []const u8, parsed_flags: Flags) Self {
            if (emit_ast) @compileError("use initWithAllocator() for emit_ast=true");
            return .{
                .source = source,
                .flags = parsed_flags,
            };
        }

        /// AST 빌드 초기화 (emit_ast=true).
        /// allocator는 AST 노드와 extra_data 저장에 사용.
        pub fn initWithAllocator(source: []const u8, parsed_flags: Flags, alloc: std.mem.Allocator) Self {
            if (!emit_ast) @compileError("initWithAllocator() requires emit_ast=true");
            var nodes = std.ArrayList(ast.Node).init(alloc);
            var extra = std.ArrayList(u32).init(alloc);
            // 대부분의 정규식은 32개 미만 노드 → 재할당 최소화
            nodes.ensureTotalCapacity(32) catch {};
            extra.ensureTotalCapacity(64) catch {};
            return .{
                .source = source,
                .flags = parsed_flags,
                .ast_nodes = nodes,
                .ast_extra = extra,
            };
        }

        /// AST 모드 리소스 해제.
        pub fn deinit(self: *Self) void {
            if (emit_ast) {
                self.ast_nodes.deinit();
                self.ast_extra.deinit();
            }
        }

        /// 패턴을 검증한다 (emit_ast=false 전용).
        /// 에러가 있으면 에러 메시지, 없으면 null.
        pub fn validate(self: *Self) ?[]const u8 {
            if (emit_ast) @compileError("use parse() for emit_ast=true");
            self.parseAndFinalize();
            return self.err_message;
        }

        /// 패턴을 파싱하여 AST를 반환한다 (emit_ast=true 전용).
        /// 에러가 있으면 null, 에러 메시지는 getError()로 조회.
        ///
        /// 호출자는 반드시 다음 패턴을 따라야 한다:
        ///   var p = Parser.initWithAllocator(...);
        ///   defer p.deinit();           // 파서 내부 버퍼 해제
        ///   var tree = p.parse() orelse return;
        ///   defer tree.deinit();        // AST 소유 메모리 해제
        pub fn parse(self: *Self) ?ast.RegExpAst {
            if (!emit_ast) @compileError("use validate() for emit_ast=false");

            self.parseAndFinalize();
            if (self.err_message != null) return null;

            // toOwnedSlice로 소유권 이전 — 호출자가 RegExpAst.deinit()으로 해제.
            // toOwnedSlice 후 ArrayList는 capacity=0이므로 p.deinit()은 안전한 no-op.
            const alloc = self.ast_nodes.allocator;
            const nodes = self.ast_nodes.toOwnedSlice() catch return null;
            const extra = self.ast_extra.toOwnedSlice() catch {
                alloc.free(nodes); // 첫 번째 할당 정리
                return null;
            };
            return .{
                .nodes = nodes,
                .extra_data = extra,
                .root = self.last_node,
                .source = self.source,
                .allocator = alloc,
            };
        }

        /// 파싱 + 후처리 검증 (validate/parse 공통).
        fn parseAndFinalize(self: *Self) void {
            self.parseDisjunction();
            if (self.err_message != null) return;

            // 소스 끝까지 소비하지 않았으면 에러
            if (self.pos < self.source.len) {
                self.err_message = "unexpected character in regular expression";
                return;
            }

            // back reference가 group count보다 크면 에러 (unicode mode에서)
            if (self.flags.hasUnicodeMode() and self.max_back_ref > self.group_count) {
                self.err_message = "invalid back reference in regular expression";
                return;
            }

            // named back reference가 정의된 named group을 참조하는지 검증
            for (self.named_refs[0..self.named_ref_count]) |ref_name| {
                var found = false;
                for (self.named_groups[0..self.named_group_count]) |group_name| {
                    if (std.mem.eql(u8, ref_name, group_name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    self.err_message = "invalid named back reference: group not defined";
                    return;
                }
            }
        }

        /// 에러 메시지를 반환한다.
        pub fn getError(self: *const Self) ?[]const u8 {
            return self.err_message;
        }

        // ================================================================
        // AST 빌드 헬퍼 (emit_ast=true에서만 호출됨)
        // ================================================================

        /// 노드를 추가하고 인덱스를 반환한다.
        fn addNode(self: *Self, tag: ast.Tag, span: ast.Span, data: [3]u32) ast.NodeIndex {
            if (emit_ast) {
                self.ast_nodes.append(.{
                    .tag = tag,
                    .span = span,
                    .data = data,
                }) catch {
                    self.setError("out of memory building regexp AST");
                    return .none;
                };
                return @enumFromInt(@as(u32, @intCast(self.ast_nodes.items.len - 1)));
            }
            unreachable;
        }

        /// extra_data에 값을 추가한다.
        fn appendExtra(self: *Self, value: u32) void {
            if (emit_ast) {
                self.ast_extra.append(value) catch {
                    self.setError("out of memory building regexp AST");
                };
            }
        }

        /// 현재 extra_data 길이를 반환한다 (리스트 시작 위치 추적용).
        fn extraLen(self: *const Self) u32 {
            if (emit_ast) {
                return @intCast(self.ast_extra.items.len);
            }
            return 0;
        }

        /// class atom의 codepoint 값을 설정한다 (range 검증용).
        fn setClassValue(self: *Self, value: u32) void {
            self.last_class_value = value;
            self.last_class_is_class_escape = false;
        }

        /// 고정 크기 버퍼에 값을 추가한다. 오버플로 시 에러를 설정하고 false 반환.
        fn bufAppend(self: *Self, buf: anytype, len: anytype, value: u32) bool {
            if (emit_ast) {
                if (len.* < buf.len) {
                    buf[len.*] = value;
                    len.* += 1;
                    return true;
                }
                self.setError("too many items in regular expression");
                return false;
            }
            return true;
        }

        // ================================================================
        // 핵심 파싱 함수
        // ================================================================

        /// Disjunction -> Alternative ('|' Alternative)*
        ///
        /// 자식 alternative의 NodeIndex를 스택 버퍼에 모은 뒤
        /// 한꺼번에 extra_data에 flush한다.
        /// (중첩 호출이 extra_data를 공유하므로, 직접 push하면 인터리빙됨)
        fn parseDisjunction(self: *Self) void {
            const span_start = self.pos;

            self.parseAlternative();

            if (emit_ast) {
                // 스택 버퍼에 alternative 인덱스를 모은다
                var buf: [64]u32 = undefined;
                var buf_len: u32 = 0;
                buf[0] = @intFromEnum(self.last_node);
                buf_len = 1;

                while (self.eat('|')) {
                    self.parseAlternative();
                    if (buf_len < 64) {
                        buf[buf_len] = @intFromEnum(self.last_node);
                        buf_len += 1;
                    } else {
                        self.setError("too many alternatives in regular expression");
                        return;
                    }
                }

                // extra_data에 연속으로 flush
                const list_start = self.extraLen();
                for (buf[0..buf_len]) |idx| {
                    self.appendExtra(idx);
                }
                self.last_node = self.addNode(.disjunction, .{
                    .start = span_start,
                    .end = self.pos,
                }, .{ list_start, buf_len, 0 });
            } else {
                while (self.eat('|')) {
                    self.parseAlternative();
                }
            }
        }

        /// Alternative -> Term*
        ///
        /// 자식 term의 NodeIndex를 스택 버퍼에 모은 뒤 flush.
        fn parseAlternative(self: *Self) void {
            const span_start = self.pos;

            if (emit_ast) {
                var buf: [256]u32 = undefined;
                var buf_len: u32 = 0;

                while (!self.isEnd() and self.peek() != '|' and self.peek() != ')') {
                    self.parseTerm();
                    if (self.err_message != null) {
                        // 에러 시 부분 노드 생성
                        const list_start = self.extraLen();
                        for (buf[0..buf_len]) |idx| self.appendExtra(idx);
                        self.last_node = self.addNode(.alternative, .{
                            .start = span_start,
                            .end = self.pos,
                        }, .{ list_start, buf_len, 0 });
                        return;
                    }
                    if (buf_len < 256) {
                        buf[buf_len] = @intFromEnum(self.last_node);
                        buf_len += 1;
                    } else {
                        self.setError("too many terms in regular expression alternative");
                        return;
                    }
                }

                const list_start = self.extraLen();
                for (buf[0..buf_len]) |idx| self.appendExtra(idx);
                self.last_node = self.addNode(.alternative, .{
                    .start = span_start,
                    .end = self.pos,
                }, .{ list_start, buf_len, 0 });
            } else {
                while (!self.isEnd() and self.peek() != '|' and self.peek() != ')') {
                    self.parseTerm();
                    if (self.err_message != null) return;
                }
            }
        }

        /// Term -> Assertion | Atom Quantifier?
        fn parseTerm(self: *Self) void {
            // Assertion: ^, $, \b, \B, lookahead/lookbehind
            if (self.parseAssertion()) return;

            // Atom
            if (!self.parseAtom()) {
                if (self.err_message == null) {
                    self.setError("unexpected character in regular expression");
                }
                return;
            }

            // Quantifier: *, +, ?, {n,m}
            // last_node는 parseAtom이 설정. parseQuantifier가 감쌀 수 있음.
            self.parseQuantifier();
        }

        // ================================================================
        // Assertion
        // ================================================================

        fn parseAssertion(self: *Self) bool {
            if (self.isEnd()) return false;
            const c = self.peek();

            if (c == '^' or c == '$') {
                self.advance();
                if (emit_ast) {
                    const kind: ast.BoundaryAssertionKind = if (c == '^') .start else .end;
                    self.last_node = self.addNode(.boundary_assertion, .{
                        .start = self.pos - 1,
                        .end = self.pos,
                    }, .{ @intFromEnum(kind), 0, 0 });
                }
                return true;
            }

            // \b, \B (word boundary)
            if (c == '\\' and self.pos + 1 < self.source.len) {
                const next = self.source[self.pos + 1];
                if (next == 'b' or next == 'B') {
                    self.pos += 2;
                    if (emit_ast) {
                        const kind: ast.BoundaryAssertionKind =
                            if (next == 'b') .boundary else .negative_boundary;
                        self.last_node = self.addNode(.boundary_assertion, .{
                            .start = self.pos - 2,
                            .end = self.pos,
                        }, .{ @intFromEnum(kind), 0, 0 });
                    }
                    return true;
                }
            }

            // Lookahead/Lookbehind: (?=...), (?!...), (?<=...), (?<!...)
            if (c == '(' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '?') {
                if (self.pos + 2 < self.source.len) {
                    const third = self.source[self.pos + 2];
                    if (third == '=' or third == '!') {
                        const assert_start = self.pos;
                        self.pos += 3;
                        self.parseDisjunction();
                        const body = if (emit_ast) self.last_node else {};
                        if (!self.eat(')')) self.setError("unterminated lookahead assertion");
                        if (emit_ast) {
                            const kind: ast.LookAroundAssertionKind =
                                if (third == '=') .lookahead else .negative_lookahead;
                            self.last_node = self.addNode(.lookaround_assertion, .{
                                .start = assert_start,
                                .end = self.pos,
                            }, .{ @intFromEnum(kind), @intFromEnum(body), 0 });
                        }
                        return true;
                    }
                    if (third == '<' and self.pos + 3 < self.source.len) {
                        const fourth = self.source[self.pos + 3];
                        if (fourth == '=' or fourth == '!') {
                            const assert_start = self.pos;
                            self.pos += 4;
                            self.parseDisjunction();
                            const body = if (emit_ast) self.last_node else {};
                            if (!self.eat(')')) self.setError("unterminated lookbehind assertion");
                            if (emit_ast) {
                                const kind: ast.LookAroundAssertionKind =
                                    if (fourth == '=') .lookbehind else .negative_lookbehind;
                                self.last_node = self.addNode(.lookaround_assertion, .{
                                    .start = assert_start,
                                    .end = self.pos,
                                }, .{ @intFromEnum(kind), @intFromEnum(body), 0 });
                            }
                            return true;
                        }
                    }
                }
            }

            return false;
        }

        // ================================================================
        // Atom
        // ================================================================

        fn parseAtom(self: *Self) bool {
            if (self.isEnd()) return false;
            const c = self.peek();

            switch (c) {
                '.' => {
                    self.advance();
                    if (emit_ast) {
                        self.last_node = self.addNode(.dot, .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        }, .{ 0, 0, 0 });
                    }
                    return true;
                },
                '\\' => return self.parseEscape(),
                '[' => return self.parseCharacterClass(),
                '(' => return self.parseGroup(),
                // quantifier without atom — 에러
                '*', '+', '?' => {
                    self.setError("unexpected quantifier without preceding atom");
                    return false;
                },
                '{' => {
                    // unicode mode에서 standalone {는 에러
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected quantifier without preceding atom");
                        return false;
                    }
                    // non-unicode mode에서는 literal
                    self.advance();
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        }, .{ '{', @intFromEnum(ast.CharacterKind.symbol), 0 });
                    }
                    return true;
                },
                '}' => {
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected '}' in regular expression");
                        return false;
                    }
                    self.advance();
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        }, .{ '}', @intFromEnum(ast.CharacterKind.symbol), 0 });
                    }
                    return true;
                },
                ']' => {
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("unexpected ']' in regular expression");
                        return false;
                    }
                    self.advance();
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        }, .{ ']', @intFromEnum(ast.CharacterKind.symbol), 0 });
                    }
                    return true;
                },
                ')' => return false, // alternative 종료
                else => {
                    self.advance();
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = self.pos - 1,
                            .end = self.pos,
                        }, .{ c, @intFromEnum(ast.CharacterKind.symbol), 0 });
                    }
                    return true;
                },
            }
        }

        // ================================================================
        // Escape
        // ================================================================

        fn parseEscape(self: *Self) bool {
            if (self.pos + 1 >= self.source.len) {
                self.setError("unterminated escape sequence in regular expression");
                return false;
            }
            const bs_pos = self.pos; // backslash 위치
            self.advance(); // skip '\'
            const c = self.peek();

            switch (c) {
                // Character class escapes
                'd', 'D', 'w', 'W', 's', 'S' => {
                    self.advance();
                    self.last_class_is_class_escape = true;
                    if (emit_ast) {
                        const kind: ast.CharacterClassEscapeKind = switch (c) {
                            'd' => .d,
                            'D' => .negative_d,
                            'w' => .w,
                            'W' => .negative_w,
                            's' => .s,
                            'S' => .negative_s,
                            else => unreachable,
                        };
                        self.last_node = self.addNode(.character_class_escape, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ @intFromEnum(kind), 0, 0 });
                    }
                    return true;
                },
                // Control escape
                'f', 'n', 'r', 't', 'v' => {
                    self.advance();
                    const value: u32 = switch (c) {
                        'f' => 0x0C,
                        'n' => 0x0A,
                        'r' => 0x0D,
                        't' => 0x09,
                        'v' => 0x0B,
                        else => unreachable,
                    };
                    self.setClassValue(value);
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ value, @intFromEnum(ast.CharacterKind.single_escape), 0 });
                    }
                    return true;
                },
                // \cX control character
                'c' => {
                    self.advance();
                    if (!self.isEnd()) {
                        const ctrl = self.peek();
                        if ((ctrl >= 'a' and ctrl <= 'z') or (ctrl >= 'A' and ctrl <= 'Z')) {
                            self.advance();
                            self.setClassValue(ctrl & 0x1F);
                            if (emit_ast) {
                                self.last_node = self.addNode(.character, .{
                                    .start = bs_pos,
                                    .end = self.pos,
                                }, .{ ctrl & 0x1F, @intFromEnum(ast.CharacterKind.control_letter), 0 });
                            }
                            return true;
                        }
                    }
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("invalid control character escape");
                        return false;
                    }
                    self.setClassValue('c');
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ 'c', @intFromEnum(ast.CharacterKind.identifier), 0 });
                    }
                    return true;
                },
                // \0 null
                '0' => {
                    self.advance();
                    if (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid octal escape in unicode mode");
                            return false;
                        }
                        const octal_start = self.pos - 1;
                        while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '7') {
                            self.advance();
                        }
                        const val = computeOctalValue(self.source, octal_start, self.pos);
                        self.setClassValue(val);
                        if (emit_ast) {
                            self.last_node = self.addNode(.character, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ val, @intFromEnum(ast.CharacterKind.octal), 0 });
                        }
                    } else {
                        self.setClassValue(0);
                        if (emit_ast) {
                            self.last_node = self.addNode(.character, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ 0, @intFromEnum(ast.CharacterKind.null_char), 0 });
                        }
                    }
                    return true;
                },
                // \xHH hex escape
                'x' => {
                    self.advance();
                    const hex_start = self.pos;
                    if (!self.eatHexDigits(2)) {
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid hex escape in regular expression");
                            return false;
                        }
                        self.setClassValue('x');
                        if (emit_ast) {
                            self.last_node = self.addNode(.character, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ 'x', @intFromEnum(ast.CharacterKind.identifier), 0 });
                        }
                    } else {
                        const val = computeHexValue(self.source, hex_start, self.pos);
                        self.setClassValue(val);
                        if (emit_ast) {
                            self.last_node = self.addNode(.character, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ val, @intFromEnum(ast.CharacterKind.hexadecimal_escape), 0 });
                        }
                    }
                    return true;
                },
                // \uHHHH or \u{HHHH} unicode escape
                'u' => {
                    self.advance();
                    if (self.eat('{')) {
                        const hex_start = self.pos;
                        if (!self.eatHexDigitsUntil('}')) {
                            self.setError("invalid unicode escape in regular expression");
                            return false;
                        }
                        const val = computeHexValue(self.source, hex_start, self.pos - 1);
                        // \u{...} codepoint 범위 검증: U+0000 ~ U+10FFFF
                        if (val > 0x10FFFF) {
                            self.setError("unicode codepoint must not be greater than 0x10FFFF");
                            return false;
                        }
                        self.setClassValue(val);
                        if (emit_ast) {
                            self.last_node = self.addNode(.character, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ val, @intFromEnum(ast.CharacterKind.unicode_escape), 0 });
                        }
                    } else {
                        const hex_start = self.pos;
                        if (!self.eatHexDigits(4)) {
                            if (self.flags.hasUnicodeMode()) {
                                self.setError("invalid unicode escape in regular expression");
                                return false;
                            }
                            self.setClassValue('u');
                            if (emit_ast) {
                                self.last_node = self.addNode(.character, .{
                                    .start = bs_pos,
                                    .end = self.pos,
                                }, .{ 'u', @intFromEnum(ast.CharacterKind.identifier), 0 });
                            }
                        } else {
                            const val = computeHexValue(self.source, hex_start, self.pos);
                            self.setClassValue(val);
                            if (emit_ast) {
                                self.last_node = self.addNode(.character, .{
                                    .start = bs_pos,
                                    .end = self.pos,
                                }, .{ val, @intFromEnum(ast.CharacterKind.unicode_escape), 0 });
                            }
                        }
                    }
                    return true;
                },
                // \p{...} or \P{...} unicode property escape
                'p', 'P' => {
                    if (self.flags.hasUnicodeMode()) {
                        const negative = (c == 'P');
                        self.advance();
                        if (!self.eat('{')) {
                            self.setError("invalid unicode property escape");
                            return false;
                        }
                        // name (= value)? 파싱
                        const name_start = self.pos;
                        while (!self.isEnd() and self.peek() != '=' and self.peek() != '}') {
                            self.advance();
                        }
                        const name_end = self.pos;
                        const name = self.source[name_start..name_end];

                        var value_start: u32 = 0;
                        var value_end: u32 = 0;
                        var has_value = false;
                        if (self.eat('=')) {
                            has_value = true;
                            value_start = self.pos;
                            while (!self.isEnd() and self.peek() != '}') {
                                self.advance();
                            }
                            value_end = self.pos;
                        }

                        if (!self.eat('}')) {
                            self.setError("unterminated unicode property escape");
                            return false;
                        }

                        // 프로퍼티 검증
                        if (has_value) {
                            const value = self.source[value_start..value_end];
                            if (!unicode_property.isValidUnicodeProperty(name, value)) {
                                self.setError("invalid unicode property name or value");
                                return false;
                            }
                        } else {
                            var is_valid = unicode_property.isValidLoneUnicodeProperty(name);
                            if (!is_valid) {
                                // v-flag: property-of-strings 확인
                                if (self.flags.v and unicode_property.isValidPropertyOfStrings(name)) {
                                    if (negative) {
                                        self.setError("negated unicode property of strings is not allowed");
                                        return false;
                                    }
                                    is_valid = true;
                                }
                            }
                            if (!is_valid) {
                                self.setError("invalid unicode property name");
                                return false;
                            }
                        }

                        self.last_class_is_class_escape = true; // property escape도 range endpoint 불가
                        if (emit_ast) {
                            self.last_node = self.addNode(.unicode_property_escape, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{
                                name_start,
                                name_end,
                                @as(u32, @intFromBool(negative)),
                            });
                        }
                        return true;
                    }
                    // non-unicode: literal
                    self.advance();
                    self.setClassValue(c);
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ c, @intFromEnum(ast.CharacterKind.identifier), 0 });
                    }
                    return true;
                },
                // \k<name> named back reference
                'k' => {
                    self.advance();
                    if (self.eat('<')) {
                        const ref_name_start = self.pos;
                        if (!self.parseGroupName()) return false;
                        // 참조 이름을 수집 (파싱 끝에서 존재 검증)
                        const ref_name = self.source[ref_name_start .. self.pos - 1];
                        if (self.named_ref_count < 32) {
                            self.named_refs[self.named_ref_count] = ref_name;
                            self.named_ref_count += 1;
                        } else {
                            self.setError("too many named back references");
                            return false;
                        }
                        if (emit_ast) {
                            self.last_node = self.addNode(.named_reference, .{
                                .start = bs_pos,
                                .end = self.pos,
                            }, .{ ref_name_start, self.pos - 1, 0 });
                        }
                        return true;
                    }
                    // \k 뒤에 <가 없으면: unicode에서 에러, non-unicode에서 identity escape
                    if (self.flags.hasUnicodeMode()) {
                        self.setError("invalid named back reference");
                        return false;
                    }
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ 'k', @intFromEnum(ast.CharacterKind.identifier), 0 });
                    }
                    return true;
                },
                // Back reference \1-\9
                '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    var ref_num: u32 = 0;
                    while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                        ref_num = ref_num *| 10 +| (self.peek() - '0'); // saturating arithmetic
                        self.advance();
                    }
                    if (ref_num > self.max_back_ref) self.max_back_ref = ref_num;
                    if (emit_ast) {
                        self.last_node = self.addNode(.indexed_reference, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ ref_num, 0, 0 });
                    }
                    return true;
                },
                // Identity escape — unicode mode에서는 제한
                else => {
                    if (self.flags.hasUnicodeMode()) {
                        if (isSyntaxChar(c)) {
                            self.advance();
                            self.setClassValue(c);
                            if (emit_ast) {
                                self.last_node = self.addNode(.character, .{
                                    .start = bs_pos,
                                    .end = self.pos,
                                }, .{ c, @intFromEnum(ast.CharacterKind.identifier), 0 });
                            }
                            return true;
                        }
                        self.setError("invalid escape sequence in unicode mode");
                        return false;
                    }
                    self.advance();
                    self.setClassValue(c);
                    if (emit_ast) {
                        self.last_node = self.addNode(.character, .{
                            .start = bs_pos,
                            .end = self.pos,
                        }, .{ c, @intFromEnum(ast.CharacterKind.identifier), 0 });
                    }
                    return true;
                },
            }
        }

        // ================================================================
        // Character Class
        // ================================================================

        fn parseCharacterClass(self: *Self) bool {
            const class_start = self.pos;
            self.advance(); // skip '['
            const negated = self.eat('^');

            // emit_ast=true일 때만 버퍼 할당 (스택 절약)
            var buf: if (emit_ast) [128]u32 else void = if (emit_ast) undefined else {};
            var buf_len: if (emit_ast) u32 else void = if (emit_ast) 0 else {};

            // nested class에서 outer 상태를 보존하기 위해 save/restore
            const saved_contents_kind = self.last_class_contents_kind;

            if (self.flags.v) {
                self.last_class_contents_kind = .@"union";
                self.parseClassSetExpression(&buf, &buf_len);
                if (self.err_message != null) return false;
            } else {
                // ── 기존 모드: 단순 atom + range ──
                while (!self.isEnd() and self.peek() != ']') {
                    const atom_pos = self.pos;
                    if (!self.parseClassAtom()) {
                        if (self.err_message != null) return false;
                    }
                    const first_node = if (emit_ast) self.last_node else {};
                    const first_value = self.last_class_value;
                    const first_is_escape = self.last_class_is_class_escape;

                    // range: a-z
                    if (!self.isEnd() and self.peek() == '-') {
                        self.advance();
                        if (!self.isEnd() and self.peek() != ']') {
                            if (!self.parseClassAtom()) {
                                if (self.err_message != null) return false;
                            }
                            if (self.flags.hasUnicodeMode()) {
                                if (first_is_escape or self.last_class_is_class_escape) {
                                    self.setError("character class escape cannot be used in range");
                                    return false;
                                }
                            }
                            if (!first_is_escape and !self.last_class_is_class_escape) {
                                if (first_value > self.last_class_value) {
                                    self.setError("character class range out of order");
                                    return false;
                                }
                            }
                            if (emit_ast) {
                                const second_node = self.last_node;
                                const range_node = self.addNode(.character_class_range, .{
                                    .start = atom_pos,
                                    .end = self.pos,
                                }, .{
                                    @intFromEnum(first_node),
                                    @intFromEnum(second_node),
                                    0,
                                });
                                if (!self.bufAppend(&buf, &buf_len, @intFromEnum(range_node))) return false;
                            }
                        } else {
                            if (emit_ast) {
                                if (!self.bufAppend(&buf, &buf_len, @intFromEnum(first_node))) return false;
                                const dash_node = self.addNode(.character, .{
                                    .start = self.pos - 1,
                                    .end = self.pos,
                                }, .{ '-', @intFromEnum(ast.CharacterKind.symbol), 0 });
                                if (!self.bufAppend(&buf, &buf_len, @intFromEnum(dash_node))) return false;
                            }
                        }
                    } else {
                        if (emit_ast) {
                            if (!self.bufAppend(&buf, &buf_len, @intFromEnum(first_node))) return false;
                        }
                    }
                }
            }

            if (!self.eat(']')) {
                self.setError("unterminated character class");
                return false;
            }

            if (emit_ast) {
                const list_start = self.extraLen();
                for (buf[0..buf_len]) |idx| self.appendExtra(idx);
                // flags: bit 0 = negative, bits 1-2 = CharacterClassContentsKind
                const kind_bits: u32 = if (self.flags.v)
                    @intFromEnum(self.last_class_contents_kind)
                else
                    0; // non-v-flag: 항상 union(0)
                const flags_val: u32 = @intFromBool(negated) | (kind_bits << 1);
                self.last_node = self.addNode(.character_class, .{
                    .start = class_start,
                    .end = self.pos,
                }, .{ flags_val, list_start, buf_len });
            }

            // outer class의 contents kind 복원 (nested class 호출 후)
            self.last_class_contents_kind = saved_contents_kind;
            return true;
        }

        fn parseClassAtom(self: *Self) bool {
            if (self.isEnd()) return false;
            if (self.peek() == '\\') {
                return self.parseEscape();
            }
            const ch = self.peek();
            self.last_class_value = ch;
            self.last_class_is_class_escape = false;
            self.advance();
            if (emit_ast) {
                self.last_node = self.addNode(.character, .{
                    .start = self.pos - 1,
                    .end = self.pos,
                }, .{ ch, @intFromEnum(ast.CharacterKind.symbol), 0 });
            }
            return true;
        }

        // ================================================================
        // Group
        // ================================================================

        fn parseGroup(self: *Self) bool {
            const group_start = self.pos;
            self.advance(); // skip '('

            if (!self.isEnd() and self.peek() == '?') {
                self.advance(); // skip '?'
                if (self.isEnd()) {
                    self.setError("unterminated group");
                    return false;
                }
                const gc = self.peek();
                switch (gc) {
                    ':' => {
                        // non-capturing group (?:...)
                        self.advance();
                        self.parseDisjunction();
                        if (!self.eat(')')) {
                            self.setError("unterminated group");
                            return false;
                        }
                        if (emit_ast) {
                            const body = self.last_node;
                            self.last_node = self.addNode(.ignore_group, .{
                                .start = group_start,
                                .end = self.pos,
                            }, .{ 0, 0, @intFromEnum(body) });
                        }
                        return true;
                    },
                    '<' => {
                        // named group (?<name>...)
                        self.advance();
                        const name_s = self.pos;
                        // 그룹 이름 유효성: IdentifierName (ID_Start + ID_Continue*)
                        if (!self.parseGroupName()) return false;
                        const name_e = self.pos - 1; // -1 for '>'
                        const name = self.source[name_s..name_e];
                        // 중복 이름 체크
                        for (self.named_groups[0..self.named_group_count]) |existing| {
                            if (std.mem.eql(u8, existing, name)) {
                                self.setError("duplicate named capturing group");
                                return false;
                            }
                        }
                        if (self.named_group_count < 32) {
                            self.named_groups[self.named_group_count] = name;
                            self.named_group_count += 1;
                        } else {
                            self.setError("too many named capturing groups");
                            return false;
                        }
                        self.group_count += 1;

                        self.parseDisjunction();
                        if (!self.eat(')')) {
                            self.setError("unterminated group");
                            return false;
                        }
                        if (emit_ast) {
                            const body = self.last_node;
                            self.last_node = self.addNode(.capturing_group, .{
                                .start = group_start,
                                .end = self.pos,
                            }, .{ name_s, name_e, @intFromEnum(body) });
                        }
                        return true;
                    },
                    // inline modifiers (?ims:...) or (?ims-ims:...)
                    'i', 'm', 's', '-' => {
                        if (!self.parseModifiers()) return false;
                        self.parseDisjunction();
                        if (!self.eat(')')) {
                            self.setError("unterminated group");
                            return false;
                        }
                        if (emit_ast) {
                            const body = self.last_node;
                            self.last_node = self.addNode(.ignore_group, .{
                                .start = group_start,
                                .end = self.pos,
                            }, .{ 0, 0, @intFromEnum(body) });
                        }
                        return true;
                    },
                    else => {
                        self.setError("invalid group specifier");
                        return false;
                    },
                }
            } else {
                // capturing group (...)
                self.group_count += 1;

                self.parseDisjunction();
                if (!self.eat(')')) {
                    self.setError("unterminated group");
                    return false;
                }
                if (emit_ast) {
                    const body = self.last_node;
                    self.last_node = self.addNode(.capturing_group, .{
                        .start = group_start,
                        .end = self.pos,
                    }, .{ std.math.maxInt(u32), 0, @intFromEnum(body) });
                }
                return true;
            }
        }

        // ================================================================
        // Modifiers (?ims-ims:...)
        // ================================================================

        fn parseModifiers(self: *Self) bool {
            var seen_i: bool = false;
            var seen_m: bool = false;
            var seen_s: bool = false;
            // positive modifiers
            while (!self.isEnd() and isModifierChar(self.peek())) {
                switch (self.peek()) {
                    'i' => {
                        if (seen_i) {
                            self.setError("duplicate modifier 'i'");
                            return false;
                        }
                        seen_i = true;
                    },
                    'm' => {
                        if (seen_m) {
                            self.setError("duplicate modifier 'm'");
                            return false;
                        }
                        seen_m = true;
                    },
                    's' => {
                        if (seen_s) {
                            self.setError("duplicate modifier 's'");
                            return false;
                        }
                        seen_s = true;
                    },
                    else => {},
                }
                self.advance();
            }
            // optional '-' for negative modifiers
            if (!self.isEnd() and self.peek() == '-') {
                self.advance();
                while (!self.isEnd() and isModifierChar(self.peek())) {
                    switch (self.peek()) {
                        'i' => {
                            if (seen_i) {
                                self.setError("modifier 'i' already set");
                                return false;
                            }
                            seen_i = true;
                        },
                        'm' => {
                            if (seen_m) {
                                self.setError("modifier 'm' already set");
                                return false;
                            }
                            seen_m = true;
                        },
                        's' => {
                            if (seen_s) {
                                self.setError("modifier 's' already set");
                                return false;
                            }
                            seen_s = true;
                        },
                        else => {},
                    }
                    self.advance();
                }
            }
            if (!self.eat(':')) {
                self.setError("invalid modifier group, expected ':'");
                return false;
            }
            return true;
        }

        // ================================================================
        // Group Name (IdentifierName)
        // ================================================================

        /// named group 이름을 파싱하고 `>`로 닫힘을 검증한다.
        /// ECMAScript: GroupName = `<` RegExpIdentifierName `>`
        /// RegExpIdentifierName = RegExpIdentifierStart RegExpIdentifierPart*
        fn parseGroupName(self: *Self) bool {
            if (self.isEnd() or self.peek() == '>') {
                self.setError("empty group name");
                return false;
            }
            // 첫 글자: ID_Start 또는 \u escape
            if (!self.parseGroupNameChar(true)) {
                self.setError("invalid group name start character");
                return false;
            }
            // 나머지: ID_Continue 또는 \u escape
            while (!self.isEnd() and self.peek() != '>') {
                if (!self.parseGroupNameChar(false)) {
                    self.setError("invalid character in group name");
                    return false;
                }
            }
            if (!self.eat('>')) {
                self.setError("unterminated group name");
                return false;
            }
            return true;
        }

        /// 그룹 이름의 한 문자를 파싱한다.
        /// is_start=true이면 ID_Start, false이면 ID_Continue 체크.
        fn parseGroupNameChar(self: *Self, is_start: bool) bool {
            if (self.isEnd()) return false;
            const gc = self.peek();

            // \u escape in group name
            if (gc == '\\') {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == 'u') {
                    self.pos += 2; // skip \u
                    // \u{HHHH} or \uHHHH
                    if (self.eat('{')) {
                        if (!self.eatHexDigitsUntil('}')) {
                            self.setError("invalid unicode escape in group name");
                            return false;
                        }
                    } else {
                        if (!self.eatHexDigits(4)) {
                            self.setError("invalid unicode escape in group name");
                            return false;
                        }
                    }
                    return true; // escape의 코드포인트 검증은 생략 (대부분의 케이스를 잡음)
                }
                return false;
            }

            // ASCII 식별자 문자 체크
            if (gc == '_' or gc == '$') {
                self.advance();
                return true;
            }
            if (is_start) {
                if ((gc >= 'a' and gc <= 'z') or (gc >= 'A' and gc <= 'Z')) {
                    self.advance();
                    return true;
                }
            } else {
                if ((gc >= 'a' and gc <= 'z') or (gc >= 'A' and gc <= 'Z') or (gc >= '0' and gc <= '9')) {
                    self.advance();
                    return true;
                }
            }

            // Non-ASCII: UTF-8 multi-byte 문자 (Unicode ID_Start/ID_Continue)
            if (gc >= 0x80) {
                // unicode mode에서 non-ASCII는 에러 (유효한 Unicode escape를 사용해야 함)
                if (self.flags.hasUnicodeMode()) {
                    return false;
                }
                self.advance();
                // multi-byte UTF-8: 후속 바이트 스킵
                while (!self.isEnd() and (self.peek() & 0xC0) == 0x80) {
                    self.advance();
                }
                return true;
            }

            return false;
        }

        // ================================================================
        // Quantifier
        // ================================================================

        fn parseQuantifier(self: *Self) void {
            if (self.isEnd()) return;
            const qc = self.peek();

            switch (qc) {
                '*', '+', '?' => {
                    if (emit_ast) {
                        const span_start = self.pos;
                        self.advance();
                        const greedy = !self.eat('?');
                        const qmin: u32 = if (qc == '+') 1 else 0;
                        const qmax: u32 = if (qc == '?') 1 else std.math.maxInt(u32);
                        const atom_node = self.last_node;
                        self.last_node = self.addNode(.quantifier, .{
                            .start = span_start,
                            .end = self.pos,
                        }, .{
                            qmin,
                            qmax,
                            (@intFromEnum(atom_node) & 0x7FFFFFFF) | (@as(u32, @intFromBool(greedy)) << 31),
                        });
                    } else {
                        self.advance();
                        _ = self.eat('?'); // lazy modifier
                    }
                },
                '{' => {
                    if (emit_ast) {
                        const saved = self.pos;
                        self.advance(); // skip '{'
                        if (self.eatDigitValue()) |min_val| {
                            var max_val: u32 = min_val;
                            if (self.eat(',')) {
                                max_val = self.eatDigitValue() orelse std.math.maxInt(u32);
                            }
                            if (self.eat('}')) {
                                const greedy = !self.eat('?');
                                const atom_node = self.last_node;
                                self.last_node = self.addNode(.quantifier, .{
                                    .start = saved,
                                    .end = self.pos,
                                }, .{
                                    min_val,
                                    max_val,
                                    (@intFromEnum(atom_node) & 0x7FFFFFFF) | (@as(u32, @intFromBool(greedy)) << 31),
                                });
                                return;
                            }
                        }
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid braced quantifier");
                            return;
                        }
                        // non-unicode: rollback, treat '{' as literal
                        self.pos = saved;
                    } else {
                        const saved = self.pos;
                        self.advance(); // skip '{'
                        if (self.eatDigits()) {
                            if (self.eat(',')) {
                                _ = self.eatDigits(); // optional max
                            }
                            if (self.eat('}')) {
                                _ = self.eat('?'); // lazy
                                return;
                            }
                        }
                        // invalid braced quantifier
                        if (self.flags.hasUnicodeMode()) {
                            self.setError("invalid braced quantifier");
                            return;
                        }
                        // non-unicode: rollback, treat '{' as literal
                        self.pos = saved;
                    }
                },
                else => {},
            }
        }

        // ================================================================
        // 헬퍼 함수
        // ================================================================

        fn peek(self: *const Self) u8 {
            return self.source[self.pos];
        }

        fn advance(self: *Self) void {
            if (self.pos < self.source.len) self.pos += 1;
        }

        fn isEnd(self: *const Self) bool {
            return self.pos >= self.source.len;
        }

        fn eat(self: *Self, expected: u8) bool {
            if (!self.isEnd() and self.peek() == expected) {
                self.advance();
                return true;
            }
            return false;
        }

        fn eatDigits(self: *Self) bool {
            if (self.isEnd() or self.peek() < '0' or self.peek() > '9') return false;
            while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                self.advance();
            }
            return true;
        }

        /// 숫자를 파싱하여 값을 반환한다. 숫자가 없으면 null.
        fn eatDigitValue(self: *Self) ?u32 {
            if (self.isEnd() or self.peek() < '0' or self.peek() > '9') return null;
            var val: u32 = 0;
            while (!self.isEnd() and self.peek() >= '0' and self.peek() <= '9') {
                val = val *| 10 +| (self.peek() - '0'); // saturating arithmetic
                self.advance();
            }
            return val;
        }

        fn eatHexDigits(self: *Self, count: u32) bool {
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                if (self.isEnd()) return false;
                const hc = self.peek();
                if (!isHexDigit(hc)) return false;
                self.advance();
            }
            return true;
        }

        fn eatHexDigitsUntil(self: *Self, terminator: u8) bool {
            var count: u32 = 0;
            while (!self.isEnd() and self.peek() != terminator) {
                if (!isHexDigit(self.peek())) return false;
                self.advance();
                count += 1;
            }
            if (count == 0) return false;
            return self.eat(terminator);
        }

        /// 두 문자를 연속으로 확인한다.
        fn peek2(self: *const Self, c1: u8, c2: u8) bool {
            return self.pos + 1 < self.source.len and
                self.source[self.pos] == c1 and
                self.source[self.pos + 1] == c2;
        }

        /// 두 문자를 연속으로 소비한다.
        fn eat2(self: *Self, c1: u8, c2: u8) bool {
            if (self.peek2(c1, c2)) {
                self.pos += 2;
                return true;
            }
            return false;
        }

        // ================================================================
        // v-flag (unicodeSets) Character Class
        // ================================================================

        /// v-flag character class의 내용물을 파싱한다.
        /// `[` 와 `]` 사이의 내용. buf/buf_len에 자식 노드 인덱스를 수집한다.
        fn parseClassSetExpression(self: *Self, buf: anytype, buf_len: anytype) void {
            if (self.isEnd() or self.peek() == ']') return;

            // 1. range 시도 (a-z)
            if (self.tryClassSetRange(buf, buf_len)) {
                self.parseClassSetUnion(buf, buf_len);
                return;
            }

            // 2. operand 시도 (nested class, \q{}, character)
            if (!self.parseClassSetOperand()) {
                if (self.err_message == null and !self.isEnd() and self.peek() != ']') {
                    self.setError("invalid character in v-flag character class");
                }
                return;
            }
            if (emit_ast) {
                if (!self.bufAppend(buf, buf_len, @intFromEnum(self.last_node))) return;
            }

            // 3. 연산자 확인: && → intersection, -- → subtraction, else → union
            if (self.peek2('&', '&')) {
                self.last_class_contents_kind = .intersection;
                self.parseClassIntersection(buf, buf_len);
            } else if (self.peek2('-', '-')) {
                self.last_class_contents_kind = .subtraction;
                self.parseClassSubtraction(buf, buf_len);
            } else {
                self.last_class_contents_kind = .@"union";
                self.parseClassSetUnion(buf, buf_len);
            }
        }

        /// Union: 나머지 term들을 수집한다 (range + operand 혼합 가능).
        fn parseClassSetUnion(self: *Self, buf: anytype, buf_len: anytype) void {
            while (!self.isEnd() and self.peek() != ']') {
                if (self.err_message != null) return;

                // range 시도
                if (self.tryClassSetRange(buf, buf_len)) continue;

                // operand 시도
                if (self.parseClassSetOperand()) {
                    if (emit_ast) {
                if (!self.bufAppend(buf, buf_len, @intFromEnum(self.last_node))) return;
            }
                    continue;
                }

                // 어떤 것도 파싱 못함 → 종료
                if (self.err_message == null and !self.isEnd() and self.peek() != ']') {
                    self.setError("invalid character in v-flag character class");
                }
                return;
            }
        }

        /// Intersection: `&&` 로 구분된 operand 목록.
        fn parseClassIntersection(self: *Self, buf: anytype, buf_len: anytype) void {
            while (!self.isEnd() and self.peek() != ']') {
                if (self.err_message != null) return;
                if (!self.eat2('&', '&')) {
                    self.setError("expected '&&' in class intersection");
                    return;
                }
                // &&& 방지
                if (!self.isEnd() and self.peek() == '&') {
                    self.setError("unexpected third '&' in class intersection");
                    return;
                }
                if (!self.parseClassSetOperand()) {
                    if (self.err_message == null)
                        self.setError("expected operand after '&&'");
                    return;
                }
                if (emit_ast) {
                if (!self.bufAppend(buf, buf_len, @intFromEnum(self.last_node))) return;
            }
            }
        }

        /// Subtraction: `--` 로 구분된 operand 목록.
        fn parseClassSubtraction(self: *Self, buf: anytype, buf_len: anytype) void {
            while (!self.isEnd() and self.peek() != ']') {
                if (self.err_message != null) return;
                if (!self.eat2('-', '-')) {
                    self.setError("expected '--' in class subtraction");
                    return;
                }
                if (!self.parseClassSetOperand()) {
                    if (self.err_message == null)
                        self.setError("expected operand after '--'");
                    return;
                }
                if (emit_ast) {
                if (!self.bufAppend(buf, buf_len, @intFromEnum(self.last_node))) return;
            }
            }
        }

        /// Range 시도 (checkpoint/rewind). 성공 시 buf에 추가하고 true.
        fn tryClassSetRange(self: *Self, buf: anytype, buf_len: anytype) bool {
            const saved_pos = self.pos;
            const saved_err = self.err_message;
            const saved_class_val = self.last_class_value;
            const saved_class_esc = self.last_class_is_class_escape;
            const saved_last_node = if (emit_ast) self.last_node else {};
            const saved_nodes = if (emit_ast) self.ast_nodes.items.len else 0;
            const saved_extra = if (emit_ast) self.ast_extra.items.len else 0;

            if (self.parseClassSetCharacter()) {
                const first_val = self.last_class_value;
                const first_node = if (emit_ast) self.last_node else {};
                if (self.eat('-')) {
                    if (!self.isEnd() and self.peek() != ']') {
                        if (self.parseClassSetCharacter()) {
                            if (first_val > self.last_class_value) {
                                self.setError("character class range out of order");
                                return false;
                            }
                            if (emit_ast) {
                                const second_node = self.last_node;
                                const range_node = self.addNode(.character_class_range, .{
                                    .start = saved_pos,
                                    .end = self.pos,
                                }, .{
                                    @intFromEnum(first_node),
                                    @intFromEnum(second_node),
                                    0,
                                });
                                if (!self.bufAppend(buf, buf_len, @intFromEnum(range_node))) return false;
                            }
                            return true;
                        }
                    }
                }
            }

            // 완전한 rollback (위치, 에러, class 상태, AST 모두 복원)
            self.pos = saved_pos;
            self.err_message = saved_err;
            self.last_class_value = saved_class_val;
            self.last_class_is_class_escape = saved_class_esc;
            if (emit_ast) {
                self.last_node = saved_last_node;
                self.ast_nodes.items.len = saved_nodes;
                self.ast_extra.items.len = saved_extra;
            }
            return false;
        }

        /// ClassSetOperand: nested class, \q{}, 또는 single character.
        fn parseClassSetOperand(self: *Self) bool {
            if (self.isEnd()) return false;

            // nested class [...]
            if (self.peek() == '[') {
                return self.parseCharacterClass();
            }

            // \q{...} class string disjunction
            if (self.peek() == '\\' and self.pos + 1 < self.source.len and
                self.source[self.pos + 1] == 'q' and
                self.pos + 2 < self.source.len and self.source[self.pos + 2] == '{')
            {
                return self.parseClassStringDisjunction();
            }

            // single character (escape 포함)
            return self.parseClassSetCharacter();
        }

        /// ClassSetCharacter: v-flag에서 유효한 단일 문자.
        fn parseClassSetCharacter(self: *Self) bool {
            if (self.isEnd()) return false;
            const ch = self.peek();

            // escape
            if (ch == '\\') {
                return self.parseEscape();
            }

            // v-flag 문법 문자는 리터럴로 사용 불가
            if (isClassSetSyntaxChar(ch)) return false;

            // 예약된 이중 구두점 방지 (&&, !!, ## 등)
            if (self.pos + 1 < self.source.len) {
                if (isClassSetReservedDoublePunct(ch, self.source[self.pos + 1])) return false;
            }

            self.advance();
            self.setClassValue(ch);
            if (emit_ast) {
                self.last_node = self.addNode(.character, .{
                    .start = self.pos - 1,
                    .end = self.pos,
                }, .{ ch, @intFromEnum(ast.CharacterKind.symbol), 0 });
            }
            return true;
        }

        /// \q{...} class string disjunction.
        fn parseClassStringDisjunction(self: *Self) bool {
            const start = self.pos;
            self.pos += 3; // skip \q{

            var str_buf: if (emit_ast) [64]u32 else void = if (emit_ast) undefined else {};
            var str_len: if (emit_ast) u32 else void = if (emit_ast) 0 else {};

            // 첫 번째 string 파싱
            self.parseClassString(&str_buf, &str_len);
            if (self.err_message != null) return false;

            while (self.eat('|')) {
                self.parseClassString(&str_buf, &str_len);
                if (self.err_message != null) return false;
            }

            if (!self.eat('}')) {
                self.setError("unterminated class string disjunction \\q{...}");
                return false;
            }

            self.last_class_is_class_escape = true; // \q{} 는 range endpoint 불가
            if (emit_ast) {
                const list_start = self.extraLen();
                for (str_buf[0..str_len]) |idx| self.appendExtra(idx);
                self.last_node = self.addNode(.class_string_disjunction, .{
                    .start = start,
                    .end = self.pos,
                }, .{ list_start, str_len, 0 });
            }
            return true;
        }

        /// \q{} 내의 단일 string (| 또는 } 까지).
        fn parseClassString(self: *Self, outer_buf: anytype, outer_len: anytype) void {
            const start = self.pos;

            var char_buf: if (emit_ast) [64]u32 else void = if (emit_ast) undefined else {};
            var char_len: if (emit_ast) u32 else void = if (emit_ast) 0 else {};

            while (!self.isEnd() and self.peek() != '|' and self.peek() != '}') {
                if (!self.parseClassSetCharacter()) {
                    if (self.err_message == null)
                        self.setError("invalid character in class string");
                    return;
                }
                if (emit_ast) {
                    if (!self.bufAppend(&char_buf, &char_len, @intFromEnum(self.last_node))) return;
                }
            }

            if (emit_ast) {
                const list_start = self.extraLen();
                for (char_buf[0..char_len]) |idx| self.appendExtra(idx);
                const string_node = self.addNode(.class_string, .{
                    .start = start,
                    .end = self.pos,
                }, .{ list_start, char_len, 0 });
                if (!self.bufAppend(outer_buf, outer_len, @intFromEnum(string_node))) return;
            }
        }

        fn setError(self: *Self, msg: []const u8) void {
            if (self.err_message == null) {
                self.err_message = msg;
                self.err_offset = self.pos;
            }
        }
    };
}

// ================================================================
// 모듈 스코프 헬퍼 함수
// ================================================================

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

fn isModifierChar(c: u8) bool {
    return c == 'i' or c == 'm' or c == 's';
}

/// v-flag: character class 내에서 리터럴로 사용할 수 없는 문법 문자.
fn isClassSetSyntaxChar(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|' => true,
        else => false,
    };
}

/// v-flag: 예약된 이중 구두점 (&&, !!, ## 등).
/// 두 문자가 같고 예약 목록에 있으면 true.
fn isClassSetReservedDoublePunct(c1: u8, c2: u8) bool {
    return c1 == c2 and switch (c1) {
        '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
        else => false,
    };
}

/// 16진수 문자를 값으로 변환한다.
fn hexDigitValue(c: u8) u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => 0,
    };
}

/// 소스의 [start, end) 범위를 16진수로 해석하여 값을 반환한다.
fn computeHexValue(source: []const u8, start: u32, end: u32) u32 {
    var val: u32 = 0;
    for (source[start..end]) |c| {
        val = val *| 16 +| hexDigitValue(c);
    }
    return val;
}

/// 소스의 [start, end) 범위를 8진수로 해석하여 값을 반환한다.
fn computeOctalValue(source: []const u8, start: u32, end: u32) u32 {
    var val: u32 = 0;
    for (source[start..end]) |c| {
        val = val *| 8 +| (c - '0');
    }
    return val;
}

// ============================================================
// Tests — 검증 모드 (emit_ast=false)
// ============================================================

test "basic patterns" {
    const P = PatternParser(false);
    {
        var p = P.init("abc", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a|b|c", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("a*b+c?", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "character class" {
    const P = PatternParser(false);
    {
        var p = P.init("[abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[a-z]", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("[^abc]", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "groups" {
    const P = PatternParser(false);
    {
        var p = P.init("(abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?:abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
    {
        var p = P.init("(?<name>abc)", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "unterminated group" {
    const P = PatternParser(false);
    var p = P.init("(abc", .{});
    try std.testing.expect(p.validate() != null);
}

test "lone quantifier" {
    const P = PatternParser(false);
    {
        var p = P.init("*", .{});
        try std.testing.expect(p.validate() != null);
    }
    {
        var p = P.init("+abc", .{});
        try std.testing.expect(p.validate() != null);
    }
}

test "unicode mode identity escape" {
    const P = PatternParser(false);
    {
        // \M is invalid in unicode mode
        var p = P.init("\\M", .{ .u = true });
        try std.testing.expect(p.validate() != null);
    }
    {
        // \M is valid in non-unicode mode
        var p = P.init("\\M", .{});
        try std.testing.expect(p.validate() == null);
    }
}

test "duplicate named group" {
    const P = PatternParser(false);
    var p = P.init("(?<a>x)(?<a>y)", .{});
    try std.testing.expect(p.validate() != null);
}

test "braced quantifier without atom in unicode mode" {
    const P = PatternParser(false);
    var p = P.init("{2,3}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

// ============================================================
// Tests — AST 모드 (emit_ast=true)
// ============================================================

test "AST: basic literal pattern" {
    // "abc" → Disjunction > Alternative > [Character('a'), Character('b'), Character('c')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("abc", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    try std.testing.expect(tree.nodeCount() > 0);

    // 루트는 disjunction
    const root = tree.getNode(tree.root);
    try std.testing.expectEqual(ast.Tag.disjunction, root.tag);

    // 1개 alternative
    const alts = root.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), alts.len);

    // alternative 안에 3개 character
    const alt_idx: ast.NodeIndex = @enumFromInt(tree.extra_data[alts.start]);
    const alt = tree.getNode(alt_idx);
    try std.testing.expectEqual(ast.Tag.alternative, alt.tag);
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 3), terms.len);

    // 각 character 검증
    const ch0 = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch0.tag);
    try std.testing.expectEqual(@as(u32, 'a'), ch0.data[0]);

    const ch1 = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 1]));
    try std.testing.expectEqual(@as(u32, 'b'), ch1.data[0]);

    const ch2 = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 2]));
    try std.testing.expectEqual(@as(u32, 'c'), ch2.data[0]);
}

test "AST: alternation" {
    // "a|b" → Disjunction > [Alternative('a'), Alternative('b')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("a|b", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    try std.testing.expectEqual(ast.Tag.disjunction, root.tag);

    const alts = root.getNodeList();
    try std.testing.expectEqual(@as(u32, 2), alts.len);
}

test "AST: capturing group" {
    // "(a)" → Disjunction > Alternative > CapturingGroup > Disjunction > Alternative > Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("(a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt_idx: ast.NodeIndex = @enumFromInt(tree.extra_data[alts.start]);
    const alt = tree.getNode(alt_idx);
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), terms.len);

    // capturing group
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.capturing_group, group.tag);
    // unnamed: name_start == 0xFFFFFFFF
    try std.testing.expectEqual(std.math.maxInt(u32), group.data[0]);
}

test "AST: named group" {
    // "(?<foo>a)" → CapturingGroup with name
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?<foo>a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.capturing_group, group.tag);
    // name_start != 0xFFFFFFFF (has name)
    try std.testing.expect(group.data[0] != std.math.maxInt(u32));
    // name은 "foo"
    const name = tree.source[group.data[0]..group.data[1]];
    try std.testing.expectEqualStrings("foo", name);
}

test "AST: quantifier" {
    // "a*" → Disjunction > Alternative > Quantifier(min=0, max=unbounded, greedy) > Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("a*", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 1), terms.len);

    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 0), quant.data[0]); // min = 0
    try std.testing.expectEqual(std.math.maxInt(u32), quant.data[1]); // max = unbounded
    try std.testing.expect(quant.isGreedy()); // greedy

    // body는 character
    const body = tree.getNode(quant.getQuantifierBody());
    try std.testing.expectEqual(ast.Tag.character, body.tag);
}

test "AST: lazy quantifier" {
    // "a+?" → Quantifier(min=1, max=unbounded, lazy)
    const P = PatternParser(true);
    var p = P.initWithAllocator("a+?", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));

    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 1), quant.data[0]); // min = 1
    try std.testing.expectEqual(std.math.maxInt(u32), quant.data[1]); // max = unbounded
    try std.testing.expect(!quant.isGreedy()); // lazy
}

test "AST: dot" {
    const P = PatternParser(true);
    var p = P.initWithAllocator(".", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const dot = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.dot, dot.tag);
}

test "AST: character class escape" {
    // "\\d" → CharacterClassEscape(d)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\d", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const node = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class_escape, node.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassEscapeKind.d)), node.data[0]);
}

test "AST: character class" {
    // "[abc]" → CharacterClass(negative=false) > [Character('a'), Character('b'), Character('c')]
    const P = PatternParser(true);
    var p = P.initWithAllocator("[abc]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // not negated
    try std.testing.expectEqual(@as(u32, 0), cc.data[0] & 1);
    // 3 members
    const body = cc.getClassBody();
    try std.testing.expectEqual(@as(u32, 3), body.len);
}

test "AST: character class range" {
    // "[a-z]" → CharacterClass > [CharacterClassRange(a, z)]
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a-z]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    const body = cc.getClassBody();
    try std.testing.expectEqual(@as(u32, 1), body.len);

    const range = tree.getNode(@enumFromInt(tree.extra_data[body.start]));
    try std.testing.expectEqual(ast.Tag.character_class_range, range.tag);
    // min = 'a', max = 'z'
    const min_ch = tree.getNode(@enumFromInt(range.data[0]));
    const max_ch = tree.getNode(@enumFromInt(range.data[1]));
    try std.testing.expectEqual(@as(u32, 'a'), min_ch.data[0]);
    try std.testing.expectEqual(@as(u32, 'z'), max_ch.data[0]);
}

test "AST: negated character class" {
    // "[^x]" → CharacterClass(negative=true)
    const P = PatternParser(true);
    var p = P.initWithAllocator("[^x]", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // negated
    try std.testing.expectEqual(@as(u32, 1), cc.data[0] & 1);
}

test "AST: boundary assertion" {
    // "^a$" → [BoundaryAssertion(start), Character('a'), BoundaryAssertion(end)]
    const P = PatternParser(true);
    var p = P.initWithAllocator("^a$", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 3), terms.len);

    const caret = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.boundary_assertion, caret.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.BoundaryAssertionKind.start)), caret.data[0]);

    const dollar = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 2]));
    try std.testing.expectEqual(ast.Tag.boundary_assertion, dollar.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.BoundaryAssertionKind.end)), dollar.data[0]);
}

test "AST: non-capturing group" {
    // "(?:a)" → IgnoreGroup
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?:a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const group = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.ignore_group, group.tag);
}

test "AST: indexed reference" {
    // "\\1" → IndexedReference(1)
    const P = PatternParser(true);
    var p = P.initWithAllocator("(a)\\1", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    try std.testing.expectEqual(@as(u32, 2), terms.len);

    const ref = tree.getNode(@enumFromInt(tree.extra_data[terms.start + 1]));
    try std.testing.expectEqual(ast.Tag.indexed_reference, ref.tag);
    try std.testing.expectEqual(@as(u32, 1), ref.data[0]);
}

test "AST: lookahead assertion" {
    // "(?=a)" → LookAroundAssertion(lookahead)
    const P = PatternParser(true);
    var p = P.initWithAllocator("(?=a)", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const la = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.lookaround_assertion, la.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.LookAroundAssertionKind.lookahead)), la.data[0]);
}

test "AST: escape characters" {
    // "\\n" → Character(0x0A, single_escape)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\n", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const ch = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch.tag);
    try std.testing.expectEqual(@as(u32, 0x0A), ch.data[0]);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterKind.single_escape)), ch.data[1]);
}

test "AST: hex escape" {
    // "\\x41" → Character(0x41, hexadecimal_escape)
    const P = PatternParser(true);
    var p = P.initWithAllocator("\\x41", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const ch = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character, ch.tag);
    try std.testing.expectEqual(@as(u32, 0x41), ch.data[0]);
}

test "AST: braced quantifier" {
    // "a{2,5}" → Quantifier(min=2, max=5, greedy) wrapping Character('a')
    const P = PatternParser(true);
    var p = P.initWithAllocator("a{2,5}", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);

    var tree = result.?;
    defer tree.deinit();
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const quant = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.quantifier, quant.tag);
    try std.testing.expectEqual(@as(u32, 2), quant.data[0]); // min
    try std.testing.expectEqual(@as(u32, 5), quant.data[1]); // max
    try std.testing.expect(quant.isGreedy());
}

test "AST: error returns null" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("(abc", .{}, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result == null);
    try std.testing.expect(p.getError() != null);
}

// ============================================================
// Tests — unicode property 검증
// ============================================================

test "unicode property: valid \\p{Lu}" {
    const P = PatternParser(false);
    var p = P.init("\\p{Lu}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{gc=Lu}" {
    const P = PatternParser(false);
    var p = P.init("\\p{gc=Lu}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{Script=Latin}" {
    const P = PatternParser(false);
    var p = P.init("\\p{Script=Latin}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: valid \\p{ASCII}" {
    const P = PatternParser(false);
    var p = P.init("\\p{ASCII}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "unicode property: invalid name" {
    const P = PatternParser(false);
    var p = P.init("\\p{NotAProperty}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: invalid gc value" {
    const P = PatternParser(false);
    var p = P.init("\\p{gc=NotACategory}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: \\P{Basic_Emoji} negated string property" {
    const P = PatternParser(false);
    // v-flag에서 \P{Basic_Emoji}는 금지
    var p = P.init("\\P{Basic_Emoji}", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "unicode property: \\p{Basic_Emoji} valid with v-flag" {
    const P = PatternParser(false);
    var p = P.init("\\p{Basic_Emoji}", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// Tests — codepoint 범위 검증
// ============================================================

test "codepoint: \\u{10FFFF} valid" {
    const P = PatternParser(false);
    var p = P.init("\\u{10FFFF}", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "codepoint: \\u{110000} invalid" {
    const P = PatternParser(false);
    var p = P.init("\\u{110000}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "codepoint: \\u{FFFFFF} invalid" {
    const P = PatternParser(false);
    var p = P.init("\\u{FFFFFF}", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

// ============================================================
// Tests — character class range 검증
// ============================================================

test "range: [a-z] valid" {
    const P = PatternParser(false);
    var p = P.init("[a-z]", .{ .u = true });
    try std.testing.expect(p.validate() == null);
}

test "range: [z-a] out of order in unicode mode" {
    const P = PatternParser(false);
    var p = P.init("[z-a]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [z-a] error in non-unicode mode too" {
    const P = PatternParser(false);
    // ECMAScript 22.2.2.9.1: range 순서는 모든 모드에서 에러
    var p = P.init("[z-a]", .{});
    try std.testing.expect(p.validate() != null);
}

test "range: [\\d-x] class escape in range (unicode mode)" {
    const P = PatternParser(false);
    var p = P.init("[\\d-x]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [a-\\d] class escape in range (unicode mode)" {
    const P = PatternParser(false);
    var p = P.init("[a-\\d]", .{ .u = true });
    try std.testing.expect(p.validate() != null);
}

test "range: [\\d-x] allowed in non-unicode mode" {
    const P = PatternParser(false);
    var p = P.init("[\\d-x]", .{});
    try std.testing.expect(p.validate() == null);
}

// ============================================================
// Tests — v-flag (unicodeSets) character class
// ============================================================

test "v-flag: simple class [abc]" {
    const P = PatternParser(false);
    var p = P.init("[abc]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: intersection [a&&b]" {
    const P = PatternParser(false);
    var p = P.init("[a&&b]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: subtraction [a--b]" {
    const P = PatternParser(false);
    var p = P.init("[a--b]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: nested class [[a-z]&&[A-Z]]" {
    const P = PatternParser(false);
    var p = P.init("[[a-z]&&[A-Z]]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: class string disjunction [\\q{abc|def}]" {
    const P = PatternParser(false);
    var p = P.init("[\\q{abc|def}]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: mixing && and -- is error" {
    const P = PatternParser(false);
    var p = P.init("[a&&b--c]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: triple & is error" {
    const P = PatternParser(false);
    var p = P.init("[a&&&b]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: range [a-z]" {
    const P = PatternParser(false);
    var p = P.init("[a-z]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag: range out of order [z-a]" {
    const P = PatternParser(false);
    var p = P.init("[z-a]", .{ .v = true });
    try std.testing.expect(p.validate() != null);
}

test "v-flag: property in class [\\p{ASCII}]" {
    const P = PatternParser(false);
    var p = P.init("[\\p{ASCII}]", .{ .v = true });
    try std.testing.expect(p.validate() == null);
}

test "v-flag AST: intersection creates correct kind" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a&&b]", .{ .v = true }, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);
    var tree = result.?;
    defer tree.deinit();

    // root > alt > character_class
    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    // kind bits at data[0] >> 1 = intersection(1)
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassContentsKind.intersection)), (cc.data[0] >> 1) & 3);
}

test "v-flag AST: subtraction creates correct kind" {
    const P = PatternParser(true);
    var p = P.initWithAllocator("[a--b]", .{ .v = true }, std.testing.allocator);
    defer p.deinit();

    const result = p.parse();
    try std.testing.expect(result != null);
    var tree = result.?;
    defer tree.deinit();

    const root = tree.getNode(tree.root);
    const alts = root.getNodeList();
    const alt = tree.getNode(@enumFromInt(tree.extra_data[alts.start]));
    const terms = alt.getNodeList();
    const cc = tree.getNode(@enumFromInt(tree.extra_data[terms.start]));
    try std.testing.expectEqual(ast.Tag.character_class, cc.tag);
    try std.testing.expectEqual(@as(u32, @intFromEnum(ast.CharacterClassContentsKind.subtraction)), (cc.data[0] >> 1) & 3);
}
