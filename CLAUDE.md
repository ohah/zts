# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript/Flow 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트. 추후 번들러까지 확장 예정.

## Tech Stack
- **Language**: Zig 0.14.0
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`
- **Test262**: `zig build test262`

## Project Structure
```
src/
  main.zig          # CLI 엔트리포인트
  root.zig          # 라이브러리 엔트리포인트
  test262.zig       # Test262 러너
  lexer.zig         # 렉서 (토크나이저) — 구현 예정
  parser.zig        # 파서 (AST 생성)
  ast.zig           # AST 노드 정의
  transformer.zig   # TS→JS 변환
  codegen.zig       # AST→JS 문자열 출력
  sourcemap.zig     # 소스맵 생성
tests/
  test262/          # TC39 공식 Test262 (서브모듈)
references/         # 레퍼런스 프로젝트 (.gitignore, 로컬만)
  bun/              # Zig — 파서/렉서 참고
  esbuild/          # Go — 아키텍처/설정 참고
  oxc/              # Rust — 트랜스포머/isolated declarations 참고
  swc/              # Rust — 전체 기능/Flow 참고
  hermes/           # C++ — Flow 파서 임베딩 소스
  metro/            # JS — React Native 번들러 참고
```

## Architecture Decisions (요약, 전체는 DECISIONS.md 참조)

### Lexer Design (D015, D019, D025, D026, D034-D036)
- **토큰 enum**: oxc 방식 — ~208개 u8 플랫 enum. TS 키워드 개별 토큰, 숫자 11가지 세분화
- **소스 위치**: start + end byte offset (8바이트). line/column은 line offset 테이블에서 lazy 계산
- **문자열 인코딩**: UTF-8 기본, lazy UTF-16 (Bun 방식)
- **렉서-파서 연동**: 파서가 렉서 호출 + 옵션으로 토큰 저장
- **SIMD**: Zig @Vector로 공백 스킵, 식별자 스캔, 문자열 스캔
- **추가 기능**: hashbang, BOM, 유니코드 식별자, import attributes, `@__PURE__` 추적, JSX pragma 감지

### Memory Strategy (D004)
- Phase-based arena allocator
- AST 노드는 포인터 대신 인덱스 기반 참조 (use-after-free 방지)

### Parser Design
- comptime으로 JS/JSX/TS/TSX/Flow 파서 각각 생성 (런타임 분기 없음)
- 에러 복구 지원 (첫 에러에서 멈추지 않음)
- Test262로 정합성 검증

### TypeScript/Flow Handling (D002, D005, D024)
- 타입 체크 안 함 (스트리핑만)
- TS 5.8까지 전체 지원
- Flow: Hermes C++ 파서를 C ABI로 링크
- Stage 3 decorator: 후순위 (스펙 안정화 후)
- Legacy decorator 우선 구현

### Output (D006, D008, D009, D012)
- ESM + CJS (UMD는 번들러 Phase)
- JSX Classic + Automatic 둘 다
- 소스맵 inline + external + hidden 전부
- 에러 출력: 코드 프레임 + JSON

### Advanced Features (Phase 6)
- ES 다운레벨링: ES2024→ES2016 점진적, ES2015는 그 이후, ES5는 미정
- WASM 플러그인, WASM 공개 AST API
- .d.ts 생성 (isolatedDeclarations)
- React Fast Refresh
- 미니파이어 (whitespace/syntax/identifiers 개별)
- 번들러 (paths/baseUrl/moduleResolution 활성화)

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 유닛 테스트
zig build test262  # Test262 러너 테스트
```

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc (crates/oxc_parser/src/lexer/kind.rs — 토큰 enum 참고)
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Hermes: github.com/facebook/hermes (Flow 파서)
- Metro: github.com/facebook/metro (RN 번들러)
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
