//! ES2015 (ES6) 다운레벨링
//!
//! --target < es2015 일 때 활성화.
//! arrow function → function + bind
//! class → function + prototype
//! let/const → var + IIFE (TDZ 에뮬레이션)
//! template literal → string concatenation
//! destructuring → 임시 변수
//! for-of → for loop
//! default parameters → 조건부 할당
//! computed property → 변수 + 대괄호
//! spread → Function.prototype.apply
//! generator → 상태 머신
//!
//! 스펙:
//! - https://tc39.es/ecma262/ (ES2015 / ES6)
//! - https://262.ecma-international.org/6.0/
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (~3000줄)
//! - oxc: crates/oxc_transformer/src/es2015/ (arrow, class, template literal 등)
//! - Babel: @babel/preset-env (ES2015 플러그인 ~20개)
//! - SWC: crates/swc_ecma_compat_es2015/
//!
//! TODO: 구현 예정 (~6000줄, 가장 큰 단일 작업)
