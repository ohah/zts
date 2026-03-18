# zts

A high-performance JavaScript/TypeScript transpiler written in Zig.

> **Status**: Early development (Phase 1 - Lexer)

## Goals

- **Fast**: SIMD-accelerated lexer, arena-based memory, cache-friendly AST
- **Correct**: Validated against Test262 test suite
- **Compatible**: Handles all TypeScript syntax (type stripping + code transforms)
- **Small**: Minimal binary size, WASM-friendly

## Build

```bash
# Prerequisites: Zig 0.14.0 (use mise for version management)
mise install

# Build
zig build

# Run
zig build run -- src/index.ts

# Test
zig build test
```

## Roadmap

See [ROADMAP.md](./ROADMAP.md) for detailed implementation plan.

## Architecture

See [CLAUDE.md](./CLAUDE.md) for architecture decisions and references.

## Design Decisions

See [DECISIONS.md](./DECISIONS.md) for pending and resolved decisions.

## References

- [Bun JS Parser](https://github.com/oven-sh/bun) (Zig, MIT)
- [oxc](https://github.com/oxc-project/oxc) (Rust, MIT)
- [SWC](https://github.com/swc-project/swc) (Rust, Apache-2.0)
- [esbuild](https://github.com/evanw/esbuild) (Go, MIT)
- [Test262](https://github.com/tc39/test262)

## License

MIT
