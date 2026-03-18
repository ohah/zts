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

---

## 추후 개선

(구현 중 발견되는 항목을 여기에 추가)
