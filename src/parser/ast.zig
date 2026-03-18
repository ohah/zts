//! ZTS AST Node Definitions
//!
//! ECMAScript / TypeScript / JSX AST 노드를 정의한다.
//! oxc/SWC를 참고하여 ~200개 세분화 노드 (D037).
//!
//! 설계 원칙:
//! - 고정 24바이트 노드 (Bun 참고, D037)
//! - 인덱스 기반 참조 (포인터 대신, D004)
//! - 카테고리별 파일 분리 (js, ts, jsx, literal)
//!
//! 참고:
//! - references/oxc/crates/oxc_ast/src/ast/
//! - references/swc/crates/swc_ecma_ast/src/

const std = @import("std");
const Span = @import("../lexer/token.zig").Span;

// ============================================================
// 인덱스 타입 — 포인터 대신 u32 인덱스로 노드를 참조 (D004)
// ============================================================

/// AST 노드 인덱스. 노드 배열의 위치를 가리킨다.
pub const NodeIndex = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    pub fn isNone(self: NodeIndex) bool {
        return self == .none;
    }
};

/// 노드 인덱스 리스트 (가변 길이 자식을 표현).
/// extra_data 배열에서 시작 위치와 길이로 참조.
pub const NodeList = struct {
    start: u32,
    len: u32,
};

/// 문자열 참조. 소스 코드의 byte offset 범위를 가리킨다.
/// 별도 문자열 테이블 없이 소스를 직접 참조 (zero-copy).
pub const StringRef = Span;

// ============================================================
// 최상위 노드 — 24바이트 고정 크기 (D037)
// ============================================================

/// AST 노드. 모든 노드가 이 구조체로 표현된다.
/// 24바이트 고정 크기 — 캐시 라인(64B)에 2.6개 들어감.
///
/// 작은 데이터는 `data` union에 인라인,
/// 큰 데이터는 extra_data 배열의 인덱스로 참조.
pub const Node = struct {
    /// 노드 종류 (2바이트)
    tag: Tag,

    /// 소스 위치 (8바이트)
    span: Span,

    /// 노드별 데이터 (14바이트, union)
    /// 작은 데이터는 인라인, 큰 데이터는 extra_data 인덱스
    data: Data,

    comptime {
        // 24바이트 고정 크기 검증
        std.debug.assert(@sizeOf(Node) == 24);
    }

    /// 노드 종류. ~200개. u16으로 표현 (256 초과 가능).
    pub const Tag = enum(u16) {
        // ==============================================================
        // Special
        // ==============================================================
        invalid = 0,

        // ==============================================================
        // Program
        // ==============================================================
        program,

        // ==============================================================
        // Literals (7개)
        // ==============================================================
        boolean_literal,
        null_literal,
        numeric_literal,
        string_literal,
        bigint_literal,
        regexp_literal,
        template_literal,

        // ==============================================================
        // Expressions (30개)
        // ==============================================================
        this_expression,
        identifier_reference,
        private_identifier,
        array_expression,
        object_expression,
        function_expression,
        arrow_function_expression,
        class_expression,
        // 단항
        unary_expression,
        update_expression,
        await_expression,
        yield_expression,
        // 이항
        binary_expression,
        logical_expression,
        // 멤버 접근
        computed_member_expression,
        static_member_expression,
        private_field_expression,
        // 호출
        call_expression,
        new_expression,
        import_expression,
        // 기타 표현식
        conditional_expression,
        assignment_expression,
        sequence_expression,
        spread_element,
        parenthesized_expression,
        chain_expression,
        tagged_template_expression,
        meta_property,
        super_expression,
        template_element,

        // ==============================================================
        // Statements (20개)
        // ==============================================================
        block_statement,
        empty_statement,
        expression_statement,
        if_statement,
        switch_statement,
        switch_case,
        while_statement,
        do_while_statement,
        for_statement,
        for_in_statement,
        for_of_statement,
        break_statement,
        continue_statement,
        return_statement,
        throw_statement,
        try_statement,
        catch_clause,
        with_statement,
        labeled_statement,
        debugger_statement,
        directive,
        hashbang,

        // ==============================================================
        // Declarations (15개)
        // ==============================================================
        variable_declaration,
        variable_declarator,
        function_declaration,
        class_declaration,
        import_declaration,
        import_specifier,
        import_default_specifier,
        import_namespace_specifier,
        import_attribute,
        export_named_declaration,
        export_default_declaration,
        export_all_declaration,
        export_specifier,

        // ==============================================================
        // Functions / Classes (15개)
        // ==============================================================
        function,
        formal_parameters,
        formal_parameter,
        rest_element,
        function_body,
        class_body,
        method_definition,
        property_definition,
        static_block,
        accessor_property,
        decorator,

        // ==============================================================
        // Patterns (10개)
        // ==============================================================
        binding_identifier,
        array_pattern,
        object_pattern,
        assignment_pattern,
        binding_property,
        binding_rest_element,
        array_assignment_target,
        object_assignment_target,
        assignment_target_with_default,

        // ==============================================================
        // Object Properties (5개)
        // ==============================================================
        object_property,
        computed_property_key,

        // ==============================================================
        // JSX (15개)
        // ==============================================================
        jsx_element,
        jsx_opening_element,
        jsx_closing_element,
        jsx_fragment,
        jsx_opening_fragment,
        jsx_closing_fragment,
        jsx_attribute,
        jsx_spread_attribute,
        jsx_expression_container,
        jsx_empty_expression,
        jsx_text,
        jsx_namespaced_name,
        jsx_member_expression,
        jsx_identifier,
        jsx_spread_child,

        // ==============================================================
        // TypeScript Types (45개)
        // ==============================================================
        ts_any_keyword,
        ts_string_keyword,
        ts_boolean_keyword,
        ts_number_keyword,
        ts_never_keyword,
        ts_unknown_keyword,
        ts_null_keyword,
        ts_undefined_keyword,
        ts_void_keyword,
        ts_symbol_keyword,
        ts_object_keyword,
        ts_bigint_keyword,
        ts_this_type,
        ts_intrinsic_keyword,
        ts_type_reference,
        ts_qualified_name,
        ts_array_type,
        ts_tuple_type,
        ts_named_tuple_member,
        ts_union_type,
        ts_intersection_type,
        ts_conditional_type,
        ts_type_operator,
        ts_optional_type,
        ts_rest_type,
        ts_indexed_access_type,
        ts_type_literal,
        ts_function_type,
        ts_constructor_type,
        ts_mapped_type,
        ts_template_literal_type,
        ts_infer_type,
        ts_parenthesized_type,
        ts_import_type,
        ts_type_query,
        ts_literal_type,
        ts_type_predicate,

        // ==============================================================
        // TypeScript Declarations (25개)
        // ==============================================================
        ts_type_alias_declaration,
        ts_interface_declaration,
        ts_interface_body,
        ts_property_signature,
        ts_method_signature,
        ts_call_signature,
        ts_construct_signature,
        ts_index_signature,
        ts_getter_signature,
        ts_setter_signature,
        ts_enum_declaration,
        ts_enum_body,
        ts_enum_member,
        ts_module_declaration,
        ts_module_block,
        ts_import_equals_declaration,
        ts_external_module_reference,
        ts_export_assignment,
        ts_namespace_export_declaration,
        ts_type_parameter,
        ts_type_parameter_declaration,
        ts_type_parameter_instantiation,
        ts_this_parameter,
        ts_class_implements,

        // ==============================================================
        // TypeScript Expressions (8개)
        // ==============================================================
        ts_as_expression,
        ts_satisfies_expression,
        ts_non_null_expression,
        ts_type_assertion,
        ts_instantiation_expression,

        // ==============================================================
        // 합계: ~200개
        // ==============================================================
    };

    /// 노드별 인라인 데이터 (14바이트).
    /// 작은 데이터는 여기에 직접 저장, 큰 데이터는 extra 인덱스로 참조.
    pub const Data = union {
        /// 단순 노드 (자식 없음): 추가 데이터 없음
        none: void,

        /// 단항 (자식 1개): left만 사용
        unary: struct {
            operand: NodeIndex,
            flags: u16 = 0, // 연산자 종류 등
        },

        /// 이항 (자식 2개)
        binary: struct {
            left: NodeIndex,
            right: NodeIndex,
            flags: u16 = 0,
        },

        /// 삼항 (자식 3개)
        ternary: struct {
            a: NodeIndex,
            b: NodeIndex,
            c: NodeIndex,
        },

        /// 리스트 참조 (가변 길이 자식)
        list: NodeList,

        /// 문자열 참조 (식별자, 리터럴 값 등)
        string_ref: StringRef,

        /// 숫자 리터럴 값 (f64의 상위/하위 비트를 나눠 저장할 수 없으므로 extra로)
        number_value: f64,

        /// extra_data 배열 인덱스 (큰 데이터용)
        extra: u32,

        /// raw bytes (최대 14바이트)
        raw: [14]u8,
    };
};

// ============================================================
// AST 저장소
// ============================================================

/// AST 전체를 저장하는 구조체.
/// 모든 노드는 nodes 배열에, 가변 길이 데이터는 extra_data에 저장.
pub const Ast = struct {
    /// 노드 배열 (24바이트 × N)
    nodes: std.ArrayList(Node),

    /// 추가 데이터 (NodeIndex 배열, 가변 길이 리스트 등)
    extra_data: std.ArrayList(u32),

    /// 소스 코드 참조 (zero-copy)
    source: []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Ast {
        return .{
            .nodes = std.ArrayList(Node).init(allocator),
            .extra_data = std.ArrayList(u32).init(allocator),
            .source = source,
        };
    }

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit();
        self.extra_data.deinit();
    }

    /// 노드를 추가하고 인덱스를 반환한다.
    pub fn addNode(self: *Ast, node: Node) !NodeIndex {
        const index: u32 = @intCast(self.nodes.items.len);
        try self.nodes.append(node);
        return @enumFromInt(index);
    }

    /// 인덱스로 노드를 가져온다.
    pub fn getNode(self: *const Ast, index: NodeIndex) Node {
        return self.nodes.items[@intFromEnum(index)];
    }

    /// extra_data에 값을 추가하고 시작 인덱스를 반환한다.
    pub fn addExtra(self: *Ast, value: u32) !u32 {
        const index: u32 = @intCast(self.extra_data.items.len);
        try self.extra_data.append(value);
        return index;
    }

    /// extra_data에 NodeIndex 리스트를 추가한다.
    pub fn addNodeList(self: *Ast, indices: []const NodeIndex) !NodeList {
        const start: u32 = @intCast(self.extra_data.items.len);
        for (indices) |idx| {
            try self.extra_data.append(@intFromEnum(idx));
        }
        return .{ .start = start, .len = @intCast(indices.len) };
    }

    /// span이 가리키는 소스 텍스트를 반환한다.
    pub fn getSourceText(self: *const Ast, span: Span) []const u8 {
        return self.source[span.start..span.end];
    }
};

// ============================================================
// Tests
// ============================================================

test "Node is 24 bytes" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Node));
}

test "Tag fits in u16" {
    const fields = @typeInfo(Node.Tag).@"enum".fields;
    try std.testing.expect(fields.len <= 65536);
    // 현재 ~200개
    try std.testing.expect(fields.len >= 190);
}

test "NodeIndex.none" {
    const idx = NodeIndex.none;
    try std.testing.expect(idx.isNone());
    const valid: NodeIndex = @enumFromInt(0);
    try std.testing.expect(!valid.isNone());
}

test "Ast basic operations" {
    var ast = Ast.init(std.testing.allocator, "const x = 1;");
    defer ast.deinit();

    const idx = try ast.addNode(.{
        .tag = .numeric_literal,
        .span = .{ .start = 10, .end = 11 },
        .data = .{ .none = {} },
    });

    const node = ast.getNode(idx);
    try std.testing.expectEqual(Node.Tag.numeric_literal, node.tag);
    try std.testing.expectEqualStrings("1", ast.getSourceText(node.span));
}

test "Ast node list" {
    var ast = Ast.init(std.testing.allocator, "");
    defer ast.deinit();

    const a = try ast.addNode(.{ .tag = .numeric_literal, .span = Span.EMPTY, .data = .{ .none = {} } });
    const b = try ast.addNode(.{ .tag = .string_literal, .span = Span.EMPTY, .data = .{ .none = {} } });

    const list = try ast.addNodeList(&.{ a, b });
    try std.testing.expectEqual(@as(u32, 2), list.len);
}
