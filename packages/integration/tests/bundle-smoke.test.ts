import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun, runZts, createFixture, ZTS_BIN } from "./helpers";
import { existsSync } from "node:fs";
import { join } from "node:path";

describe("ZTS CLI", () => {
  test("바이너리가 존재한다", () => {
    expect(existsSync(ZTS_BIN)).toBe(true);
  });

  test("--help 플래그가 동작한다", async () => {
    const { exitCode, stdout } = await runZts(["--help"]);
    expect(exitCode).toBe(0);
    expect(stdout).toContain("Usage");
  });
});

describe("번들 스모크 테스트", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  test("단일 파일 번들", async () => {
    const result = await bundleAndRun({
      "index.ts": `const msg: string = "hello"; console.log(msg);`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("hello");
  });

  test("다중 파일 import", async () => {
    const result = await bundleAndRun({
      "index.ts": `import { add } from "./math"; console.log(add(1, 2));`,
      "math.ts": `export function add(a: number, b: number): number { return a + b; }`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("3");
  });

  test("TS 타입 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        interface User { name: string; age: number; }
        const user: User = { name: "test", age: 25 };
        console.log(user.name);
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("test");
  });

  test("tree-shaking으로 미사용 모듈 제거", async () => {
    const { dir, cleanup: c } = await createFixture({
      "index.ts": `import { used } from "./used"; console.log(used);`,
      "used.ts": `export const used = "yes";`,
      "unused.ts": `export const unused = "no";`,
    });
    cleanup = c;

    const outFile = join(dir, "out.js");
    const bundle = await runZts(["--bundle", join(dir, "index.ts"), "-o", outFile]);
    expect(bundle.exitCode).toBe(0);

    const output = await Bun.file(outFile).text();
    expect(output).toContain("yes");
    // 미사용 모듈은 번들에 포함되지 않아야 함
    expect(output).not.toContain("unused.ts");
  });
});
