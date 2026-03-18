# ZTS Backlog

리뷰에서 스킵한 항목 + 추후 개선 사항을 추적한다.
각 항목은 발견된 PR과 예상 해결 시점을 기록한다.

---

## 스킵된 리뷰 항목

### PR #1: feat(lexer): token enum

| # | 항목 | 이유 | 해결 시점 |
|---|------|------|----------|
| 1 | `Span`에 `source_id` 추가 (multi-file) | 현재 single-file 처리만. multi-file은 CLI Phase에서 | Phase 5 |
| 2 | `jsx_string_literal` 별도 토큰 | JSX 속성 문자열은 escape 규칙이 다름. 파서 구현 시 필요 여부 판단 | Phase 2 |
| 3 | `legacy_octal` 별도 토큰 | octal로 파싱 후 파서에서 strict mode 체크로 대응 가능. 필요하면 추가 | Phase 2 |
| 4 | `StaticStringMap` → perfect hash 최적화 | 프로파일링 후 병목이면 교체 | Phase 1 (SIMD PR 이후) |

### PR #3: feat(lexer): base Scanner

| # | 항목 | 이유 | 해결 시점 |
|---|------|------|----------|
| 5 | scan* 함수 테이블 기반 통합 (7개 → 1개 helper) | 구조 리팩토링. 현재 동작에는 문제 없음 | 최적화 PR |
| 6 | skipWhitespace/scanIdentifierTail → local pos 패턴으로 최적화 | 이중 bounds check 제거. 성능 개선 | SIMD PR |
| 7 | handleNewline 특수화 (handleLF/handleCR) | skipWhitespace에서 이미 판별된 문자를 재검사하지 않도록 | SIMD PR |
| 8 | keyword lookup 길이 체크 early-exit (len > 11 → skip) | 긴 식별자의 불필요한 해시 계산 방지 | 최적화 PR |
| 9 | getLineColumn hint 캐싱 (last_line_hint) | 순차 접근 시 O(1) amortized | Phase 4 |
| 10 | line_offsets Small Buffer Optimization | 256줄 이하 파일에서 힙 할당 제거 | 최적화 PR |
| 11 | 미완성 string/template 에러 감지 | EOF 도달 시 syntax_error 반환 | 문자열 리터럴 PR |
| 12 | 문자열 내 줄바꿈 에러 감지 | JS 스펙: 일반 문자열에 줄바꿈 불가 | 문자열 리터럴 PR |
| 13 | scanHashbang에서 U+2028/U+2029 줄바꿈 처리 | 현재 \n, \r만 체크 | 유니코드 PR |

---

## 추후 개선

(구현 중 발견되는 항목을 여기에 추가)
