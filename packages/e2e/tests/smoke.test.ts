import { test, expect } from "@playwright/test";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ZTS_BIN = resolve(__dirname, "../../../zig-out/bin/zts");
const TEST_PORT = 3999;

let server: ChildProcess | null = null;
let fixtureDir: string;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), "zts-e2e-"));
  await writeFile(
    join(fixtureDir, "app.ts"),
    'const msg: string = "hello from zts"; console.log(msg); var el = document.getElementById("root"); if (el) { el.textContent = msg; }',
  );

  server = spawn(
    ZTS_BIN,
    ["--serve", "--bundle", join(fixtureDir, "app.ts"), "--port", String(TEST_PORT)],
    { stdio: "pipe" },
  );

  // 서버가 뜰 때까지 대기
  await new Promise((resolve) => setTimeout(resolve, 2000));
});

test.afterAll(async () => {
  if (server) {
    server.kill();
    // 프로세스 종료 대기
    await new Promise((resolve) => server!.on("close", resolve));
  }
  await rm(fixtureDir, { recursive: true, force: true });
});

test.describe("Dev Server E2E", () => {
  test("페이지가 로드되고 번들이 실행된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);
    await expect(page.locator("#root")).toHaveText("hello from zts");
  });

  test("HMR WebSocket 연결이 수립된다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    const wsConnected = await page.evaluate(
      (port: number) => {
        return new Promise<boolean>((resolve) => {
          const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
          ws.onopen = () => {
            ws.close();
            resolve(true);
          };
          ws.onerror = () => resolve(false);
          setTimeout(() => resolve(false), 3000);
        });
      },
      TEST_PORT,
    );

    expect(wsConnected).toBe(true);
  });

  test("connected 메시지를 수신한다", async ({ page }) => {
    await page.goto(`http://localhost:${TEST_PORT}/`);

    const firstMessage = await page.evaluate(
      (port: number) => {
        return new Promise<string>((resolve) => {
          const ws = new WebSocket(`ws://localhost:${port}/__hmr`);
          ws.onmessage = (e) => {
            ws.close();
            resolve(e.data);
          };
          ws.onerror = () => resolve("error");
          setTimeout(() => resolve("timeout"), 3000);
        });
      },
      TEST_PORT,
    );

    const msg = JSON.parse(firstMessage);
    expect(msg.type).toBe("connected");
  });

  test("번들에 TS 타입이 제거되어 있다", async ({ page }) => {
    const response = await page.goto(`http://localhost:${TEST_PORT}/bundle.js`);
    const body = await response!.text();

    expect(body).toContain("hello from zts");
    expect(body).not.toContain(": string");
  });
});
