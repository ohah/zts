# ZTS Backlog

리뷰에서 스킵한 항목 + 추후 개선 사항을 추적한다.
각 항목은 발견된 PR과 예상 해결 시점을 기록한다.

---

## 해결됨

| # | 항목 | 해결 PR/시점 |
|---|------|-------------|
| 2 | `jsx_string_literal` 별도 토큰 → `jsx_text` 토큰으로 처리 | Phase 2 |
| 3 | `legacy_octal` → `has_legacy_octal` 플래그 + strict mode 검증 | Phase 2 |
| 11 | 미완성 string/template 에러 감지 | PR #6 (string), PR #7 (template) |
| 12 | 문자열 내 줄바꿈 에러 감지 | PR #6 |
| 13 | scanHashbang에서 U+2028/U+2029 줄바꿈 처리 | PR #14 |
| 16 | 템플릿 이스케이프에 \xHH, \uHHHH 처리 | Phase 2 |
| 26 | scanIdentifierEscape hex 유효성 검사 | Phase 2 |
| 29 | for-in/for-of 미구현 | PR #21 |
| 30 | 에러 메시지 컨텍스트 ("Expected X but found Y") | Phase 2 |
| 32 | shorthand property | PR #25 |
| 33 | spread in array/object | PR #23 |
| 35 | async arrow function | Phase 2 |
| 36 | yield/await arrow parameter error | Phase 2 |
| 37 | async/generator 메서드 | Phase 2 |
| 38 | #private 필드/메서드 | PR #28 |
| 39 | class field ASI | Phase 2 |
| 40 | 키워드 shorthand property | Phase 2 |
| 41 | elision 전용 노드 | PR #29 |
| 42 | assignment destructuring | PR #28 |
| 43 | import.meta | PR #29 |
| 44 | string literal import specifier (ES2022) | Phase 2 |
| 45 | export default async function | Phase 2 |
| 47 | multi-param function type | Phase 2 TS |
| 48 | method/index/call signature | Phase 2 TS |
| 54 | abstract flag | Phase 2 TS |
| 56 | const enum 라우팅 | Phase 2 TS |
| 57 | interface extends 다중 타입 → NodeList 리스트 | Phase 2 TS |

---

## 미해결 — 성능 최적화 (SIMD/프로파일링 후)

| # | 항목 | 이유 |
|---|------|------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | 번들러에서 필요 |
| 4 | `StaticStringMap` → perfect hash 최적화 | 프로파일링 후 |
| 5 | scan* 함수 테이블 기반 통합 | 구조 리팩토링 |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴 | SIMD PR |
| 7 | handleNewline 특수화 | SIMD PR |
| 8 | keyword lookup 길이 체크 early-exit | 최적화 PR |
| 9 | getLineColumn hint 캐싱 | 최적화 PR |
| 10 | line_offsets Small Buffer Optimization | 최적화 PR |
| 14 | scanHexDigits/scanOctalDigits/scanBinaryDigits 통합 | 최적화 PR |
| 15 | scanHexLiteral/scanOctalLiteral/scanBinaryLiteral 통합 | 최적화 PR |
| 17 | skipUnicodeEscape 헬퍼 추출 | 최적화 PR |
| 18 | isAsciiIdentStart/Continue를 unicode.zig로 이동 | 최적화 PR |
| 19 | pragma dead guard 제거 | 최적화 PR |
| 20 | checkPureComment 최적화 (단일 패스) | 최적화 PR |
| 21 | checkJSXPragma early-exit | 최적화 PR |
| 22 | peek() 캐싱 | 최적화 PR |
| 23 | isAsciiIdentContinue → lookup table | SIMD PR |
| 24 | line_offsets/template_depth_stack 초기 용량 | 최적화 PR |
| 25 | unicode.zig 범위 테이블 불완전 (Georgian 등) | 별도 PR |
| 28 | runner.zig failed_list 메모리 누수 | Arena 도입 시 해결 |
| 31 | scratch ArrayList 미적용 일부 파싱 함수 | 최적화 PR |
| 34 | parseForIn/parseForOf 통합 | 최적화 PR |
| 46 | import() .then() 체이닝 미처리 | expression 경로로 이미 동작 |

---

## 미해결 — TS 타입 전용 (타입 체크/d.ts 생성 시 필요)

ZTS는 타입 체크를 하지 않으므로 (스트리핑만) 이 항목들은 당장 필요하지 않음.
AST Tag는 정의되어 있으나 파싱 미구현 — .d.ts 생성(isolatedDeclarations) 구현 시 추가.

| # | 항목 | 비고 |
|---|------|------|
| 49 | conditional type `T extends U ? X : Y` | Tag 정의됨, 파싱 미구현 |
| 50 | mapped type `{ [K in keyof T]: V }` | Tag 정의됨, 파싱 미구현 |
| 51 | infer type `infer T` | Tag 정의됨, 파싱 미구현 |
| 52 | template literal type `` `hello ${string}` `` | Tag 정의됨, 파싱 미구현 |
| 53 | declare 문 wrapper 노드 (ambient 구분) | .d.ts용 |
| 55 | declare global 미지원 | .d.ts용 |
| 56 | module "string" (문자열 모듈 이름) 미지원 | .d.ts용 |

---

## 추후 개선

(구현 중 발견되는 항목을 여기에 추가)
