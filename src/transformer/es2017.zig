//! ES2017 다운레벨링: async/await → generator + Promise
//!
//! --target < es2017 일 때 활성화.
//! async function f() { await x; } → function f() { return __async(function*() { yield x; }); }
//!
//! 스펙:
//! - async functions: https://tc39.es/ecma262/#sec-async-function-definitions (ES2017, TC39 Stage 4: 2016-11)
//!                     https://github.com/tc39/ecmascript-asyncawait
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerAsync)
//! - oxc: crates/oxc_transformer/src/es2017/
//! - Babel: @babel/plugin-transform-async-to-generator
//!
//! TODO: 구현 예정 (~1000줄, 런타임 헬퍼 __async 필요)
