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

  test("forward reference — 같은 이름 변수의 올바른 참조", async () => {
    // 두 모듈이 같은 이름의 top-level 변수(helper)를 갖고,
    // forward reference(helper가 greet보다 뒤에 선언)가 있을 때
    // scope hoisting 후 각 greet이 자기 모듈의 helper를 호출해야 한다.
    const result = await bundleAndRun({
      "index.ts": `import { greet as a } from "./a"; import { greet as b } from "./b"; console.log(a(), b());`,
      "a.ts": `export const greet = () => helper(); export const helper = () => "from_a";`,
      "b.ts": `export const greet = () => helper(); export const helper = () => "from_b";`,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("from_a from_b");
  });

  test("abstract 멤버 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        abstract class BaseService {
          abstract getName(): string;
          abstract readonly id: number;
          greet() { return "Hello, " + this.getName(); }
        }
        class UserService extends BaseService {
          getName() { return "User"; }
          get id() { return 1; }
        }
        console.log(new UserService().greet());
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("Hello, User");
    expect(result.bundleOutput).not.toContain("abstract");
  });

  test("declare 필드 스트리핑", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        class Config {
          declare env: string;
          declare readonly debug: boolean;
          host = "localhost";
          port = 3000;
        }
        const cfg = new Config();
        console.log(cfg.host + ":" + cfg.port);
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("localhost:3000");
    // declare 필드가 제거되어 env/debug가 undefined로 초기화되면 안 됨
    expect(result.bundleOutput).not.toContain("env");
    expect(result.bundleOutput).not.toContain("debug");
  });

  test("abstract + declare 복합 — 실전 패턴", async () => {
    const result = await bundleAndRun({
      "index.ts": `
        import { UserRepo } from "./repo";
        const repo = new UserRepo();
        console.log(repo.findAll().join(","));
      `,
      "repo.ts": `
        abstract class BaseRepo<T> {
          declare tableName: string;
          abstract findAll(): T[];
          count() { return this.findAll().length; }
        }
        export class UserRepo extends BaseRepo<string> {
          findAll() { return ["alice", "bob"]; }
        }
      `,
    });
    cleanup = result.cleanup;

    expect(result.exitCode).toBe(0);
    expect(result.runOutput).toBe("alice,bob");
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
