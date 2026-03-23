# Known Issues

스모크 테스트 + 브라우저 E2E에서 발견된 이슈 목록.

## 번들러 런타임 에러 (scope hoisting)

### zod — `z is not defined`
- **증상**: `import { z } from 'zod'` 번들 실행 시 `ReferenceError: z is not defined`
- **원인**: zod v4에서 export 구조 변경 → ZTS scope hoisting이 새 구조를 처리 못함
- **esbuild/rolldown**: 정상

### rxjs — `require_rxjs_dist_cjs_index is not defined`
- **증상**: `import { of } from 'rxjs'` 번들 실행 시 CJS wrapper 함수 참조 에러
- **원인**: CJS interop의 scope hoisting에서 `__commonJS` 래핑 함수가 누락됨
- **esbuild**: 정상 (실행도 OK)
- **rolldown**: 정상

### vue — 런타임 에러
- **증상**: vue 번들 (1593KB) 빌드 성공, 실행 시 에러
- **원인**: 대형 코드베이스에서 scope hoisting 변수 충돌 추정
- **esbuild/rolldown**: 정상

### supabase — 런타임 에러
- **증상**: `import { createClient } from '@supabase/supabase-js'` 실행 시 에러
- **원인**: scope hoisting 관련 (미조사)
- **esbuild/rolldown**: 정상

## CLI 기능 부재

### `--define` 옵션 미구현
- **영향**: `process.env.NODE_ENV` 참조하는 라이브러리 (immer, mobx 등)를 `--platform=browser`로 번들링할 수 없음
- **필요**: `--define:process.env.NODE_ENV="production"` 형태의 글로벌 치환
- **참고**: esbuild `--define:X=Y`, rolldown `--define X=Y`

## 메모리 누수 (기존)

### package_json.zig — sideEffects 배열 메모리 릭
- **증상**: `parseSideEffects`에서 할당한 patterns + 문자열이 해제되지 않음
- **위치**: `src/bundler/package_json.zig:263-270`
- **영향**: 번들링 시 leak 경고 출력 (기능에는 영향 없음)

## 구조적 개선 (후순위)

### binding_scanner — barrel re-export를 `.local`로 오분류
- **현상**: `import { X } from './a'; export { X }` 가 `.local` export로 분류됨
- **영향**: `resolveExportChain`에서 import_bindings를 O(N) 선형 탐색으로 보정
- **개선**: binding_scanner에서 `.re_export`로 정확히 분류하면 linker의 탐색 불필요
- **PR #308에서 workaround 적용 완료** (linker에서 import binding 확인)
