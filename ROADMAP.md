# ZTS Roadmap

## Vision
Zig로 작성된 고성능 JS/TS 트랜스파일러. SWC/oxc 수준의 품질과 성능.

---

## Phase 1: Lexer (렉서)
JS/TS 소스 코드를 토큰으로 분리.

### 목표
- [ ] 기본 토큰 타입 정의 (키워드, 연산자, 리터럴, 식별자)
- [ ] 숫자 리터럴 (정수, 소수, hex, octal, binary, bigint, numeric separator `_`)
- [ ] 문자열 리터럴 (single/double quote, escape sequence)
- [ ] 템플릿 리터럴 (backtick, `${expr}` 중첩)
- [ ] 정규식 리터럴 (`/` 나눗셈과 구분)
- [ ] 주석 (single-line, multi-line, hashbang)
- [ ] 자동 세미콜론 삽입 (ASI) 규칙
- [ ] 소스 위치 추적 (line, column, offset)
- [ ] SIMD 최적화 (공백 스킵, 식별자 스캔)
- [ ] 유니코드 식별자 지원

### Test262 러너
렉서/파서 구현과 동시에 Test262로 검증.

- [ ] Test262 메타데이터 파서 (YAML frontmatter: negative, flags, features 등)
- [ ] 테스트 실행기 (pass/fail 판정)
  - `negative.phase: parse` → 파서가 에러를 던져야 통과
  - `negative` 없음 → 파서가 에러 없이 파싱해야 통과
  - `flags: [module]` → ESM 모드로 파싱
  - `flags: [noStrict]` / `flags: [onlyStrict]` → strict mode 제어
- [ ] 카테고리별 실행 (`--test262 test/language/literals/`)
- [ ] 통과율 리포트 (총 N개 중 M개 통과, X% pass rate)
- [ ] CI 연동 (test262.yml 워크플로우 활성화)
- [ ] 실패 테스트 목록 출력 (디버깅용)

#### Phase 1에서 검증할 Test262 카테고리
```
test/language/literals/numeric/     ← 숫자 리터럴
test/language/literals/string/      ← 문자열 리터럴
test/language/literals/bigint/      ← BigInt
test/language/literals/boolean/     ← boolean
test/language/literals/null/        ← null
test/language/literals/regexp/      ← 정규식
test/language/comments/             ← 주석
test/language/keywords/             ← 키워드
test/language/line-terminators/     ← 줄바꿈
test/language/asi/                  ← 자동 세미콜론 삽입
```

---

## Phase 2: Parser (파서)
토큰 스트림을 AST로 변환.

### 목표
- [ ] AST 노드 타입 정의 (24바이트 고정 크기)
- [ ] Arena allocator 기반 AST 메모리 관리
- [ ] 인덱스 기반 노드 참조 (포인터 대신)

### ECMAScript 구문 (ES2024)
- [ ] 리터럴 (string, number, boolean, null, undefined, regex, template)
- [ ] 표현식 (binary, unary, ternary, assignment, comma, spread)
- [ ] 화살표 함수
- [ ] 구조분해 할당 (array, object, nested)
- [ ] 클래스 (필드, 메서드, static, private `#`, computed property)
- [ ] for...of, for...in, for await...of
- [ ] async/await
- [ ] generator (function*, yield)
- [ ] import/export (ESM)
- [ ] dynamic import (`import()`)
- [ ] optional chaining (`?.`)
- [ ] nullish coalescing (`??`)
- [ ] logical assignment (`&&=`, `||=`, `??=`)
- [ ] top-level await
- [ ] class static block (`static { }`)
- [ ] import attributes (`with { type: "json" }`)
- [ ] using / await using (Explicit Resource Management)

### TypeScript 구문 (삭제 대상)
- [ ] 타입 어노테이션 (변수, 파라미터, 리턴, 클래스 필드)
- [ ] 제네릭 (파라미터, 제약, 기본값, const, in/out variance)
- [ ] 타입 인자 (호출, new, tagged template, JSX)
- [ ] type alias
- [ ] interface (+ extends, call/construct/method/property/index signature)
- [ ] as / as const / satisfies
- [ ] non-null assertion (`!`)
- [ ] angle bracket assertion (`<Type>expr`)
- [ ] 인스턴스화 표현식 (`fn<string>` 호출 없이, TS 4.7)
- [ ] import type / export type
- [ ] inline type specifier (`import { type Foo }`, TS 4.5)
- [ ] export type * / export type * as ns (TS 5.0)
- [ ] declare (변수, 함수, 클래스, enum, module, global, 클래스 필드)
- [ ] abstract (클래스, 메서드, 프로퍼티, accessor)
- [ ] 접근 제어자 (public, private, protected)
- [ ] readonly
- [ ] override
- [ ] implements
- [ ] 함수 오버로드 시그니처
- [ ] this 파라미터
- [ ] definite assignment assertion (변수 `let x!`, 클래스 필드 `x!:`)
- [ ] 옵셔널 클래스 프로퍼티 (`x?: number`)
- [ ] 타입 가드 (x is string, asserts x is string)
- [ ] .d.ts 파일 전체 무시
- [ ] 트리플 슬래시 디렉티브
- [ ] TSX 제네릭 화살표 함수 모호성 (`<T,>() => {}`)

### TypeScript 구문 (변환 대상)
- [ ] enum → IIFE
- [ ] const enum → 인라이닝 또는 IIFE (isolatedModules 시 IIFE 폴백)
- [ ] namespace (단일) → IIFE
- [ ] namespace (병합) → 다중 IIFE
- [ ] namespace (중첩) → 중첩 IIFE
- [ ] namespace + class/function/enum 선언 병합
- [ ] 파라미터 프로퍼티 → this.x = x 생성
- [ ] export = → module.exports =
- [ ] import x = require("...") → const x = require("...")
- [ ] import x = Namespace.Value → const x = Namespace.Value
- [ ] legacy decorator (클래스, 메서드, 프로퍼티, 파라미터)
- [ ] emitDecoratorMetadata → Reflect.metadata 호출 생성
- [ ] accessor 키워드 → getter/setter 변환

### JSX
- [ ] JSX element → React.createElement / jsxs 호출
- [ ] JSX fragment
- [ ] JSX spread attributes
- [ ] JSX namespace (`<xml:svg>`)
- [ ] 자동 import (React 17+ jsx transform)

### 에러 처리
- [ ] 에러 복구 (sync token까지 스킵 후 계속 파싱)
- [ ] 에러 메시지 품질 (위치, 기대값, 실제값)
- [ ] 다중 에러 수집

### 검증
- [ ] Test262 language/ 테스트 통과율 추적

---

## Phase 3: Transformer (트랜스포머)
AST를 변환하여 JS로 출력 가능한 형태로 만듦.

### 목표
- [ ] 타입 스트리핑 (삭제 대상 노드 제거)
- [ ] enum 변환
- [ ] const enum 인라이닝
- [ ] namespace 변환 (단일, 병합, 중첩, 선언 병합)
- [ ] 파라미터 프로퍼티 변환
- [ ] export = / import = 변환
- [ ] legacy decorator 변환
- [ ] emitDecoratorMetadata
- [ ] accessor 변환
- [ ] JSX 변환

---

## Phase 4: Code Generator (코드젠)
변환된 AST를 JavaScript 문자열로 출력.

### 목표
- [ ] AST → JS 문자열 출력
- [ ] 소스맵 생성 (v3)
- [ ] 출력 포맷 옵션 (minify 기초)
- [ ] 줄바꿈, 들여쓰기 보존

---

## Phase 5: CLI & Integration
사용자가 실제로 쓸 수 있는 도구로 만듦.

### 목표
- [ ] CLI 인터페이스 (`zts src/index.ts`)
- [ ] 설정 파일 지원 (tsconfig.json 읽기)
- [ ] 파일 단위 병렬 파싱 (ThreadPool)
- [ ] 디렉토리 재귀 처리
- [ ] watch 모드
- [ ] WASM 빌드 타겟

---

## Phase 6: Advanced (추후)
스펙 안정화 및 리소스 확보 후 진행.

- [ ] Stage 3 (TC39) decorator — 스펙이 Stage 4 도달 또는 안정화 후 구현
- [ ] ES 다운레벨링 (ES2024 → ES5/ES2015 등)
- [ ] 미니파이어
- [ ] 번들러
- [ ] import defer (TS 5.9)
- [ ] 증분 파싱 (에디터 LSP 연동)

---

## Design Decisions Log

### 2026-03-18: Stage 3 Decorator 후순위
- **결정**: Stage 3 decorator는 스펙 안정화 후 구현
- **이유**: TC39 스펙이 Stage 3 도달 후에도 4회 이상 수정됨. oxc도 같은 이유로 구현 중단. SWC는 구현했으나 2년간 버그 수정 지속 중
- **대안**: Legacy decorator 우선 구현

### 2026-03-18: 타입 체크 미지원
- **결정**: 타입 체크를 하지 않음. 타입 스트리핑만
- **이유**: SWC, oxc, Bun, esbuild 모두 같은 전략. 타입 체크는 tsc에 위임
- **범위**: 구문(syntax) 파싱 + 스트리핑/변환만

### 2026-03-18: 메모리 설계
- **결정**: 인덱스 기반 AST + phase-based arena allocator
- **이유**: Bun의 포인터 기반 AST가 segfault 원인 (4800+ 오픈 이슈). 인덱스 기반으로 use-after-free 원천 차단
- **참고**: Bun 24바이트 고정 노드, oxc의 arena 패턴

### 2026-03-18: comptime 파서 특수화
- **결정**: JS/JSX/TS/TSX 파서를 comptime으로 각각 생성
- **이유**: Bun과 동일 전략. 런타임 분기 0개로 성능 극대화

### 2026-03-18: SIMD Lexer
- **결정**: Zig @Vector로 SIMD 렉서 구현
- **이유**: oxc가 안 하고 있는 영역. Bun은 Highway로 사용 중. 차별화 포인트
