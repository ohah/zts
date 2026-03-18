# ZTS Decision Records

프로젝트 진행 중 내려야 할 의사결정 목록과 현재 상태.

---

## 결정 완료

### D001: 프로그래밍 언어
- **결정**: Zig
- **이유**: 학습 목적 + arena allocator가 언어 네이티브, SIMD @Vector 빌트인, 빠른 컴파일, C ABI 호환, 작은 WASM 출력

### D002: 타입 체크
- **결정**: 안 함
- **이유**: SWC/oxc/Bun/esbuild 전부 동일 전략. tsc에 위임

### D003: Stage 3 Decorator
- **결정**: 후순위 (스펙 안정화 후)
- **이유**: oxc와 같은 전략. 스펙 불안정 + 유지보수 부담

### D004: AST 메모리 설계
- **결정**: 인덱스 기반 + arena allocator
- **이유**: 안정성 (use-after-free 방지) + 성능 (캐시 효율)

---

### D005: TypeScript 버전 지원 범위
- **결정**: TS 5.8 (최신 stable) 전체 지원, 새 버전 나오면 점진적 추가
- **이유**: TS 구문은 누적(상위 호환). 5.8 파서를 만들면 4.x도 자동 파싱. 버전별 차이는 트랜스포머 분기로 처리

### D008: JSX Transform 방식
- **결정**: Classic + Automatic 둘 다 지원
- **이유**: 파서에는 영향 없음. JSX 구문 파싱은 동일하고 트랜스포머에서 설정으로 분기. SWC/oxc 둘 다 전부 지원

### D011: isolatedModules 모드
- **결정**: 항상 isolatedModules 모드 (파일 단위 독립 처리)
- **이유**: SWC/oxc/esbuild/Bun 전부 이 방식. 크로스 파일 분석은 번들러 영역. const enum은 같은 파일 내에서만 인라이닝, 크로스 파일은 일반 enum으로 폴백

---

## 결정 필요

### D006: ESM / CJS 출력 형식
- **옵션 A**: ESM only
- **옵션 B**: ESM + CJS
- **옵션 C**: ESM + CJS + UMD
- **고려사항**: SWC는 전부 지원, esbuild도 전부 지원

### D007: ES 다운레벨링 타겟 범위
- **옵션 A**: 안 함 (타입 스트리핑 + TS 변환만)
- **옵션 B**: ES2020+ (optional chaining, nullish coalescing 등)
- **옵션 C**: ES2015까지 (arrow function, class, destructuring 등)
- **고려사항**:
  - 다운레벨링은 별도 Phase로 분리 가능
  - 처음엔 안 하고 추후 추가하는 게 현실적
  - SWC는 preset-env 수준으로 세밀하게 지원

### D009: 소스맵
- **옵션 A**: inline only
- **옵션 B**: external file (.map)
- **옵션 C**: 둘 다
- **고려사항**: 프로덕션 도구라면 둘 다 필요

### D010: tsconfig.json 지원 범위
- **어떤 옵션을 읽을 것인가?**
  - target
  - module / moduleResolution
  - jsx / jsxFactory / jsxFragmentFactory / jsxImportSource
  - experimentalDecorators / emitDecoratorMetadata
  - useDefineForClassFields
  - verbatimModuleSyntax
  - isolatedModules (항상 true로 간주할지)
  - strict (타입 체크 안 하므로 무시)
  - paths / baseUrl (번들러 영역이라 일단 무시?)
  - extends (tsconfig 상속)


### D012: 에러 출력 형식
- **옵션 A**: 단순 텍스트
- **옵션 B**: 컬러 + 코드 프레임 (SWC/oxc 스타일)
- **옵션 C**: JSON 출력 (에디터 연동)
- **고려사항**: B + C 조합이 이상적

### D013: Plugin / 확장 시스템
- **옵션 A**: 없음 (코어만)
- **옵션 B**: WASM 플러그인
- **옵션 C**: Zig 네이티브 플러그인 (comptime import)
- **고려사항**: 초기에는 A, 추후 B 고려

### D014: 공개 AST API 제공 여부
- **옵션 A**: 안 함 (Bun처럼 내부용)
- **옵션 B**: C ABI로 공개 (다른 언어에서 사용 가능)
- **옵션 C**: WASM으로 공개 (JS에서 사용 가능)
- **고려사항**: B 또는 C를 하면 linter, formatter 등이 위에 올라올 수 있음. 차별화 포인트
