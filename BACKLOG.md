# ZTS Backlog

리뷰에서 스킵한 항목 + 추후 개선 사항을 추적한다.
각 항목은 발견된 PR과 예상 해결 시점을 기록한다.

---

## 해결됨

| # | 항목 | 해결 PR |
|---|------|---------|
| 11 | 미완성 string/template 에러 감지 | PR #6 (string), PR #7 (template) |
| 12 | 문자열 내 줄바꿈 에러 감지 | PR #6 |
| 13 | scanHashbang에서 U+2028/U+2029 줄바꿈 처리 | PR #14 |

---

## 스킵된 리뷰 항목

### PR #1: feat(lexer): token enum

| # | 항목 | 이유 | 해결 시점 |
|---|------|------|----------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | 현재 single-file 처리만 | Phase 5 |
| 2 | `jsx_string_literal` 별도 토큰 | 파서 구현 시 필요 여부 판단 | Phase 2 |
| 3 | `legacy_octal` 별도 토큰 | 파서에서 strict mode 체크로 대응 가능 | Phase 2 |
| 4 | `StaticStringMap` → perfect hash 최적화 | 프로파일링 후 병목이면 교체 | 최적화 PR |

### PR #3: feat(lexer): base Scanner

| # | 항목 | 이유 | 해결 시점 |
|---|------|------|----------|
| 5 | scan* 함수 테이블 기반 통합 | 구조 리팩토링 | 최적화 PR |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴 | 이중 bounds check 제거 | SIMD PR |
| 7 | handleNewline 특수화 (handleLF/handleCR) | 재검사 방지 | SIMD PR |
| 8 | keyword lookup 길이 체크 early-exit (len < 2 or > 11 → skip) | 불필요한 해시 방지 | 최적화 PR |
| 9 | getLineColumn hint 캐싱 (last_line_hint) | O(1) amortized | Phase 4 |
| 10 | line_offsets Small Buffer Optimization | 힙 할당 제거 | 최적화 PR |

### PR #14: /simplify 전체 리뷰

| # | 항목 | 이유 | 해결 시점 |
|---|------|------|----------|
| 14 | scanHexDigits/scanOctalDigits/scanBinaryDigits 통합 (scanDigitsGeneric) | 3개 함수가 거의 동일 | 최적화 PR |
| 15 | scanHexLiteral/scanOctalLiteral/scanBinaryLiteral 통합 | 3개 wrapper 동일 패턴 | 최적화 PR |
| 16 | 템플릿 이스케이프에 \xHH, \uHHHH 처리 추가 | 현재 단순 스킵만 | Phase 2 |
| 17 | skipUnicodeEscape 헬퍼 추출 (string + identifier 공유) | 중복 코드 | 최적화 PR |
| 18 | isAsciiIdentStart/Continue를 unicode.zig로 이동 | scanner.zig와 중복 | 최적화 PR |
| 19 | pragma dead guard 제거 (@jsx vs @jsxFrag 체크) | extractPragmaValue가 이미 처리 | 최적화 PR |
| 20 | checkPureComment 최적화 (7개 indexOf → 단일 패스) | 성능: 모든 주석에서 실행됨 | 최적화 PR |
| 21 | checkJSXPragma early-exit (첫 비주석 토큰 이후 스킵) | 성능: pragma는 파일 상단만 | 최적화 PR |
| 22 | peek() 캐싱 (operator scanner에서 반복 호출) | 성능: bounds check 중복 | 최적화 PR |
| 23 | isAsciiIdentContinue → 128바이트 lookup table | 성능: 5개 비교 → 1개 인덱스 | SIMD PR |
| 24 | line_offsets/template_depth_stack 초기 용량 설정 | 성능: realloc 횟수 감소 | 최적화 PR |
| 25 | unicode.zig 범위 테이블 불완전 (Georgian, Tibetan 등 누락) | 정확성 | 별도 PR |
| 26 | scanIdentifierEscape에 hex 유효성 검사 없음 | \u{ZZZZ} 허용됨 | Phase 2 |
| 27 | /= vs regex 순서 (= /=test/ 케이스) | esbuild/Bun 동일 동작 | 문서화 완료, 수정 불필요 |
| 28 | runner.zig failed_list 메모리 누수 (에러 경로) | arena allocator로 교체 | Phase 2 |

---

## 추후 개선

(구현 중 발견되는 항목을 여기에 추가)
