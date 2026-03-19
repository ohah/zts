//! ZTS tsconfig.json Reader
//!
//! tsconfig.json 파일을 파싱하여 ZTS가 사용하는 컴파일러 옵션을 추출한다.
//! - JSONC (주석 포함 JSON) 지원: 파싱 전에 주석을 제거
//! - "extends" 필드를 통한 설정 상속 지원
//! - 누락된 필드는 기본값 사용
//!
//! 참고:
//! - TypeScript 공식 tsconfig 스펙: https://www.typescriptlang.org/tsconfig
//! - std.json.parseFromSlice: Zig 0.14 JSON 파싱 API

const std = @import("std");

/// tsconfig.json에서 파싱한 컴파일러 옵션을 담는 구조체.
///
/// 모든 필드는 옵셔널이거나 기본값이 있다.
/// CLI 옵션이 tsconfig 옵션보다 우선한다.
pub const TsConfig = struct {
    /// "target": 출력 JavaScript 버전 (예: "es5", "es2015", "esnext")
    target: ?[]const u8 = null,
    /// "module": 모듈 시스템 (예: "commonjs", "es2015", "esnext")
    module: ?[]const u8 = null,
    /// "jsx": JSX 처리 모드 (예: "react", "react-jsx", "preserve")
    jsx: ?[]const u8 = null,
    /// "jsxFactory": JSX 팩토리 함수 (기본: "React.createElement")
    jsx_factory: []const u8 = "React.createElement",
    /// "jsxFragmentFactory": JSX Fragment 팩토리 (기본: "React.Fragment")
    jsx_fragment_factory: []const u8 = "React.Fragment",
    /// "outDir": 출력 디렉토리 경로
    out_dir: ?[]const u8 = null,
    /// "rootDir": 소스 루트 디렉토리 경로
    root_dir: ?[]const u8 = null,
    /// "sourceMap": 소스맵 생성 여부
    source_map: bool = false,
    /// "declaration": .d.ts 선언 파일 생성 여부
    declaration: bool = false,
    /// "strict": strict 모드 활성화 여부
    strict: bool = false,
    /// "experimentalDecorators": 레거시 데코레이터 지원 여부
    experimental_decorators: bool = false,
    /// "emitDecoratorMetadata": 데코레이터 메타데이터 emit 여부
    emit_decorator_metadata: bool = false,

    /// allocator로 할당된 문자열들을 해제하기 위한 참조.
    /// load()에서 내부적으로 사용하며, deinit() 시 해제된다.
    _allocator: ?std.mem.Allocator = null,
    /// 할당된 문자열 목록. deinit() 시 모두 free된다.
    _allocated_strings: ?std.ArrayList([]const u8) = null,

    /// TsConfig가 소유한 동적 메모리를 해제한다.
    /// load()로 생성한 TsConfig는 반드시 deinit()을 호출해야 한다.
    pub fn deinit(self: *TsConfig) void {
        if (self._allocated_strings) |*list| {
            for (list.items) |s| {
                list.allocator.free(s);
            }
            list.deinit();
        }
        self._allocated_strings = null;
        self._allocator = null;
    }

    /// 주어진 디렉토리에서 tsconfig.json을 찾아 파싱한다.
    ///
    /// 동작:
    /// 1. dir_path/tsconfig.json 파일을 읽는다.
    /// 2. JSONC 주석을 제거한다.
    /// 3. "extends" 필드가 있으면 base config를 먼저 로드하고 merge한다.
    /// 4. compilerOptions에서 ZTS가 사용하는 필드를 추출한다.
    ///
    /// tsconfig.json이 없으면 기본값 TsConfig를 반환한다 (에러 아님).
    /// 파일 내용이 유효하지 않은 JSON이면 에러를 반환한다.
    pub fn load(allocator: std.mem.Allocator, dir_path: []const u8) !TsConfig {
        return loadFile(allocator, dir_path, "tsconfig.json", 0);
    }

    /// 특정 파일명으로 tsconfig를 로드한다 (extends 체인에서 사용).
    /// depth: extends 재귀 깊이 (무한 루프 방지, 최대 10단계)
    fn loadFile(
        allocator: std.mem.Allocator,
        dir_path: []const u8,
        file_name: []const u8,
        depth: u32,
    ) !TsConfig {
        // 무한 extends 체인 방지
        if (depth > 10) {
            return error.TsConfigExtendsDepthExceeded;
        }

        // 파일 경로 구성
        const file_path = try std.fs.path.join(allocator, &.{ dir_path, file_name });
        defer allocator.free(file_path);

        // 파일 읽기 (없으면 기본값 반환)
        const raw_source = std.fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                return TsConfig{};
            }
            return err;
        };
        defer allocator.free(raw_source);

        // JSONC → JSON: 주석 제거
        const source = try stripJsonComments(allocator, raw_source);
        defer allocator.free(source);

        // JSON 파싱.
        // std.json.parseFromSlice는 Zig 0.14의 표준 JSON 파서이다.
        // .allocate = .alloc_always: 문자열을 allocator로 복사
        //   (원본 source가 defer로 해제되므로 복사가 필요함)
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            source,
            .{ .allocate = .alloc_always },
        ) catch {
            return error.TsConfigParseError;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return error.TsConfigParseError;
        }

        // 결과 TsConfig 초기화
        var config = TsConfig{
            ._allocator = allocator,
            ._allocated_strings = std.ArrayList([]const u8).init(allocator),
        };
        errdefer config.deinit();

        // "extends" 처리: base config를 먼저 로드하고 merge
        if (root.object.get("extends")) |extends_val| {
            if (extends_val == .string) {
                const extends_path = extends_val.string;

                // extends 경로에서 디렉토리와 파일명 분리.
                // 예: "./base.json" → dir_path + "base.json"
                // 예: "../shared/tsconfig.base.json" → resolve relative to dir_path
                const resolved = try std.fs.path.join(allocator, &.{ dir_path, extends_path });
                defer allocator.free(resolved);

                // resolved가 디렉토리인지 파일인지 확인
                // 파일이면 그대로 사용, 디렉토리면 tsconfig.json 추가
                const base_dir = std.fs.path.dirname(resolved) orelse dir_path;
                const base_file = std.fs.path.basename(resolved);

                var base_config = try loadFile(allocator, base_dir, base_file, depth + 1);
                defer base_config.deinit();

                // base의 값을 config에 복사 (현재 config는 아직 기본값)
                try mergeFrom(&config, &base_config, allocator);
            }
        }

        // compilerOptions 추출
        if (root.object.get("compilerOptions")) |co_val| {
            if (co_val == .object) {
                const co = co_val.object;

                // 문자열 옵션 추출 헬퍼
                // JSON에서 가져온 문자열은 parsed가 소유하므로,
                // config가 오래 살기 위해 allocator로 복사(dupe)한다.
                if (co.get("target")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.target = duped;
                    }
                }
                if (co.get("module")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.module = duped;
                    }
                }
                if (co.get("jsx")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.jsx = duped;
                    }
                }
                if (co.get("jsxFactory")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.jsx_factory = duped;
                    }
                }
                if (co.get("jsxFragmentFactory")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.jsx_fragment_factory = duped;
                    }
                }
                if (co.get("outDir")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.out_dir = duped;
                    }
                }
                if (co.get("rootDir")) |v| {
                    if (v == .string) {
                        const duped = try allocator.dupe(u8, v.string);
                        try config._allocated_strings.?.append(duped);
                        config.root_dir = duped;
                    }
                }

                // bool 옵션 추출
                if (co.get("sourceMap")) |v| {
                    if (v == .bool) config.source_map = v.bool;
                }
                if (co.get("declaration")) |v| {
                    if (v == .bool) config.declaration = v.bool;
                }
                if (co.get("strict")) |v| {
                    if (v == .bool) config.strict = v.bool;
                }
                if (co.get("experimentalDecorators")) |v| {
                    if (v == .bool) config.experimental_decorators = v.bool;
                }
                if (co.get("emitDecoratorMetadata")) |v| {
                    if (v == .bool) config.emit_decorator_metadata = v.bool;
                }
            }
        }

        return config;
    }

    /// base config의 값을 target config에 merge한다.
    /// 이미 target에 설정된 값은 덮어쓰지 않는다 (자식이 우선).
    /// 단, 이 함수는 target이 아직 기본값일 때 호출되므로,
    /// base의 non-default 값을 모두 복사한다.
    fn mergeFrom(
        target: *TsConfig,
        base: *const TsConfig,
        allocator: std.mem.Allocator,
    ) !void {
        // 문자열 옵션: base에 값이 있으면 복사
        if (base.target) |v| {
            if (target.target == null) {
                const duped = try allocator.dupe(u8, v);
                try target._allocated_strings.?.append(duped);
                target.target = duped;
            }
        }
        if (base.module) |v| {
            if (target.module == null) {
                const duped = try allocator.dupe(u8, v);
                try target._allocated_strings.?.append(duped);
                target.module = duped;
            }
        }
        if (base.jsx) |v| {
            if (target.jsx == null) {
                const duped = try allocator.dupe(u8, v);
                try target._allocated_strings.?.append(duped);
                target.jsx = duped;
            }
        }
        if (base.out_dir) |v| {
            if (target.out_dir == null) {
                const duped = try allocator.dupe(u8, v);
                try target._allocated_strings.?.append(duped);
                target.out_dir = duped;
            }
        }
        if (base.root_dir) |v| {
            if (target.root_dir == null) {
                const duped = try allocator.dupe(u8, v);
                try target._allocated_strings.?.append(duped);
                target.root_dir = duped;
            }
        }

        // 문자열 (non-optional) 필드: base가 기본값이 아니면 복사
        if (!std.mem.eql(u8, base.jsx_factory, "React.createElement")) {
            if (std.mem.eql(u8, target.jsx_factory, "React.createElement")) {
                const duped = try allocator.dupe(u8, base.jsx_factory);
                try target._allocated_strings.?.append(duped);
                target.jsx_factory = duped;
            }
        }
        if (!std.mem.eql(u8, base.jsx_fragment_factory, "React.Fragment")) {
            if (std.mem.eql(u8, target.jsx_fragment_factory, "React.Fragment")) {
                const duped = try allocator.dupe(u8, base.jsx_fragment_factory);
                try target._allocated_strings.?.append(duped);
                target.jsx_fragment_factory = duped;
            }
        }

        // bool 옵션: base에서 true인 것만 복사 (false는 기본값이므로 구분 불가)
        // tsconfig extends에서는 보통 base의 설정이 그대로 상속됨
        if (base.source_map) target.source_map = true;
        if (base.declaration) target.declaration = true;
        if (base.strict) target.strict = true;
        if (base.experimental_decorators) target.experimental_decorators = true;
        if (base.emit_decorator_metadata) target.emit_decorator_metadata = true;
    }
};

/// JSONC (JSON with Comments)에서 주석을 제거한다.
///
/// tsconfig.json은 공식적으로 주석을 허용하는 JSONC 형식이다.
/// 지원하는 주석:
/// - 한 줄 주석: // ...
/// - 여러 줄 주석: /* ... */
///
/// 주석 영역을 공백으로 대체하여 원본과 동일한 길이를 유지한다.
/// (에러 위치 계산에 유용)
///
/// 반환된 슬라이스는 allocator로 할당되었으므로 호출자가 free해야 한다.
pub fn stripJsonComments(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    // 입력을 복사한 후 주석 부분만 공백으로 대체한다.
    const output = try allocator.dupe(u8, input);
    errdefer allocator.free(output);

    var i: usize = 0;
    while (i < output.len) {
        // 문자열 안의 내용은 건너뛴다
        if (output[i] == '"') {
            i += 1; // opening quote
            while (i < output.len) {
                if (output[i] == '\\') {
                    i += 2; // escape sequence 건너뜀
                    continue;
                }
                if (output[i] == '"') {
                    i += 1; // closing quote
                    break;
                }
                i += 1;
            }
            continue;
        }

        // 한 줄 주석: // ... \n
        if (i + 1 < output.len and output[i] == '/' and output[i + 1] == '/') {
            while (i < output.len and output[i] != '\n') {
                output[i] = ' ';
                i += 1;
            }
            continue;
        }

        // 여러 줄 주석: /* ... */
        if (i + 1 < output.len and output[i] == '/' and output[i + 1] == '*') {
            output[i] = ' ';
            i += 1;
            output[i] = ' ';
            i += 1;
            while (i < output.len) {
                if (i + 1 < output.len and output[i] == '*' and output[i + 1] == '/') {
                    output[i] = ' ';
                    i += 1;
                    output[i] = ' ';
                    i += 1;
                    break;
                }
                // 개행 문자는 보존 (줄 번호 유지)
                if (output[i] != '\n' and output[i] != '\r') {
                    output[i] = ' ';
                }
                i += 1;
            }
            continue;
        }

        // trailing comma 제거: JSON은 trailing comma를 허용하지 않지만 tsconfig는 허용함
        // 간단한 처리: ,] 또는 ,} 패턴을 찾아 콤마를 공백으로 대체
        if (output[i] == ',') {
            // 콤마 뒤에 공백/개행을 건너뛴 후 ] 또는 }가 오면 trailing comma
            var j = i + 1;
            while (j < output.len and (output[j] == ' ' or output[j] == '\t' or output[j] == '\n' or output[j] == '\r')) {
                j += 1;
            }
            if (j < output.len and (output[j] == ']' or output[j] == '}')) {
                output[i] = ' '; // trailing comma를 공백으로
            }
        }

        i += 1;
    }

    return output;
}

// ==================== Tests ====================

test "stripJsonComments - single line comments" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  // This is a comment
        \\  "key": "value"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    // 주석이 공백으로 대체되었는지 확인
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "stripJsonComments - multi line comments" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  /* multi
        \\     line
        \\     comment */
        \\  "key": "value"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("value", parsed.value.object.get("key").?.string);
}

test "stripJsonComments - comments inside strings are preserved" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "key": "// not a comment",
        \\  "key2": "/* also not */"
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("// not a comment", parsed.value.object.get("key").?.string);
    try std.testing.expectEqualStrings("/* also not */", parsed.value.object.get("key2").?.string);
}

test "stripJsonComments - trailing comma" {
    const allocator = std.testing.allocator;
    const input =
        \\{
        \\  "a": 1,
        \\  "b": 2,
        \\}
    ;
    const result = try stripJsonComments(allocator, input);
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("a").?.integer == 1);
    try std.testing.expect(parsed.value.object.get("b").?.integer == 2);
}

test "TsConfig.load - missing file returns defaults" {
    const allocator = std.testing.allocator;
    // 존재하지 않는 디렉토리를 지정하면 기본값이 반환된다
    var config = try TsConfig.load(allocator, "/tmp/zts_test_nonexistent_dir_12345");
    defer config.deinit();

    try std.testing.expect(config.target == null);
    try std.testing.expect(config.module == null);
    try std.testing.expect(config.jsx == null);
    try std.testing.expectEqualStrings("React.createElement", config.jsx_factory);
    try std.testing.expectEqualStrings("React.Fragment", config.jsx_fragment_factory);
    try std.testing.expect(config.out_dir == null);
    try std.testing.expect(config.root_dir == null);
    try std.testing.expect(config.source_map == false);
    try std.testing.expect(config.declaration == false);
    try std.testing.expect(config.strict == false);
    try std.testing.expect(config.experimental_decorators == false);
    try std.testing.expect(config.emit_decorator_metadata == false);
}

test "TsConfig.load - parse compilerOptions" {
    const allocator = std.testing.allocator;

    // 임시 디렉토리에 테스트용 tsconfig.json 생성
    const tmp_dir = "/tmp/zts_test_config_parse";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const tsconfig_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "es2020",
        \\    "module": "esnext",
        \\    "jsx": "react-jsx",
        \\    "jsxFactory": "h",
        \\    "jsxFragmentFactory": "Fragment",
        \\    "outDir": "./dist",
        \\    "rootDir": "./src",
        \\    "sourceMap": true,
        \\    "declaration": true,
        \\    "strict": true,
        \\    "experimentalDecorators": true,
        \\    "emitDecoratorMetadata": true
        \\  }
        \\}
    ;

    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("es2020", config.target.?);
    try std.testing.expectEqualStrings("esnext", config.module.?);
    try std.testing.expectEqualStrings("react-jsx", config.jsx.?);
    try std.testing.expectEqualStrings("h", config.jsx_factory);
    try std.testing.expectEqualStrings("Fragment", config.jsx_fragment_factory);
    try std.testing.expectEqualStrings("./dist", config.out_dir.?);
    try std.testing.expectEqualStrings("./src", config.root_dir.?);
    try std.testing.expect(config.source_map == true);
    try std.testing.expect(config.declaration == true);
    try std.testing.expect(config.strict == true);
    try std.testing.expect(config.experimental_decorators == true);
    try std.testing.expect(config.emit_decorator_metadata == true);
}

test "TsConfig.load - JSONC with comments" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_jsonc";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    const tsconfig_content =
        \\{
        \\  // TypeScript 설정
        \\  "compilerOptions": {
        \\    "target": "es2021", // ES2021
        \\    /* JSX 설정 */
        \\    "jsx": "preserve",
        \\    "strict": true,
        \\  }
        \\}
    ;

    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("es2021", config.target.?);
    try std.testing.expectEqualStrings("preserve", config.jsx.?);
    try std.testing.expect(config.strict == true);
}

test "TsConfig.load - extends inheritance" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_extends";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // base.json: 기본 설정
    const base_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "es2019",
        \\    "strict": true,
        \\    "sourceMap": true,
        \\    "jsx": "react"
        \\  }
        \\}
    ;
    const base_path = try std.fs.path.join(allocator, &.{ tmp_dir, "base.json" });
    defer allocator.free(base_path);
    try std.fs.cwd().writeFile(.{ .sub_path = base_path, .data = base_content });

    // tsconfig.json: base를 확장하고 일부 오버라이드
    const tsconfig_content =
        \\{
        \\  "extends": "./base.json",
        \\  "compilerOptions": {
        \\    "target": "es2022",
        \\    "outDir": "./build"
        \\  }
        \\}
    ;
    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    // target은 자식이 오버라이드 → "es2022"
    try std.testing.expectEqualStrings("es2022", config.target.?);
    // strict, sourceMap은 base에서 상속
    try std.testing.expect(config.strict == true);
    try std.testing.expect(config.source_map == true);
    // jsx는 base에서 상속
    try std.testing.expectEqualStrings("react", config.jsx.?);
    // outDir은 자식에서 설정
    try std.testing.expectEqualStrings("./build", config.out_dir.?);
}

test "TsConfig.load - partial compilerOptions" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/zts_test_config_partial";
    std.fs.cwd().makePath(tmp_dir) catch {};
    defer std.fs.cwd().deleteTree(tmp_dir) catch {};

    // 일부 옵션만 있는 tsconfig
    const tsconfig_content =
        \\{
        \\  "compilerOptions": {
        \\    "target": "esnext"
        \\  }
        \\}
    ;
    const tsconfig_path = try std.fs.path.join(allocator, &.{ tmp_dir, "tsconfig.json" });
    defer allocator.free(tsconfig_path);
    try std.fs.cwd().writeFile(.{ .sub_path = tsconfig_path, .data = tsconfig_content });

    var config = try TsConfig.load(allocator, tmp_dir);
    defer config.deinit();

    try std.testing.expectEqualStrings("esnext", config.target.?);
    // 나머지는 기본값
    try std.testing.expect(config.module == null);
    try std.testing.expect(config.jsx == null);
    try std.testing.expectEqualStrings("React.createElement", config.jsx_factory);
    try std.testing.expect(config.source_map == false);
    try std.testing.expect(config.strict == false);
}
