# ZTS - Zig TypeScript Transpiler

## Project Overview
Zig로 작성하는 JavaScript/TypeScript 트랜스파일러. SWC/oxc 수준의 프로덕션 레벨 품질을 목표로 하는 학습 + 실용 프로젝트.

## Tech Stack
- **Language**: Zig 0.14.0
- **Version Manager**: mise
- **Build**: `zig build` (build.zig)
- **Test**: `zig build test`

## Project Structure
```
src/
  main.zig          # CLI 엔트리포인트
  lexer.zig         # 렉서 (토크나이저)
  parser.zig        # 파서 (AST 생성)
  ast.zig           # AST 노드 정의
  transformer.zig   # TS→JS 변환
  codegen.zig       # AST→JS 문자열 출력
  sourcemap.zig     # 소스맵 생성
```

## Architecture Decisions

### Memory Strategy
- Phase-based arena allocator 사용
- 각 phase(lexer, parser, transform, codegen)마다 독립 arena
- AST 노드는 포인터 대신 인덱스 기반 참조 (use-after-free 방지)

### AST Design
- 24바이트 고정 크기 노드 (Bun 참고)
- 작은 타입은 인라인, 큰 타입은 포인터로 분리
- Struct-of-Arrays 레이아웃으로 캐시 효율 극대화

### Parser Design
- comptime으로 JS/JSX/TS/TSX 파서 각각 생성 (런타임 분기 없음)
- 에러 복구 지원 (첫 에러에서 멈추지 않음)
- Test262로 정합성 검증

### SIMD
- Zig @Vector 빌트인으로 SIMD 렉서 구현
- 공백 스킵, 식별자 스캔, 문자열 리터럴 스캔에 적용

### TypeScript Handling
- 타입 체크 안 함 (스트리핑만)
- Stage 3 데코레이터는 스펙 안정화 후 구현 (oxc와 같은 전략)
- Legacy 데코레이터 우선 구현

## Commands
```bash
zig build          # 빌드
zig build run      # 실행
zig build test     # 테스트
```

## References
- Bun JS Parser: github.com/oven-sh/bun (src/js_parser.zig, src/js_lexer.zig)
- oxc: github.com/oxc-project/oxc
- SWC: github.com/swc-project/swc
- esbuild: github.com/evanw/esbuild
- Test262: github.com/tc39/test262
- ECMAScript Spec: tc39.es/ecma262
