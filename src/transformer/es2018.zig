//! ES2018 다운레벨링: object rest/spread properties + async generator
//!
//! --target < es2018 일 때 활성화.
//! { ...obj } → Object.assign({}, obj)
//! { a, ...rest } = obj → (destructuring rest 풀기)
//! async function* f() {} → (async generator 변환)
//!
//! 스펙:
//! - object rest/spread: https://tc39.es/ecma262/#sec-object-initializer (ES2018, TC39 Stage 4: 2018-01)
//!                        https://github.com/tc39/proposal-object-rest-spread
//! - async iteration: https://tc39.es/ecma262/#sec-for-in-and-for-of-statements (ES2018)
//!                     https://github.com/tc39/proposal-async-iteration
//!
//! 참고:
//! - esbuild: internal/js_parser/js_parser_lower.go (lowerObjectSpread)
//! - oxc: crates/oxc_transformer/src/es2018/
//!
//! TODO: 구현 예정 (~300줄)
