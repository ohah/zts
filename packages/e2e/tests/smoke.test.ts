import { test, expect } from "@playwright/test";

test.describe("Dev Server 스모크 테스트", () => {
  test.skip(true, "dev server 미구현 — HMR 구현 후 활성화");

  test("페이지가 로드된다", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator("body")).toBeVisible();
  });

  test("HMR 연결이 수립된다", async ({ page }) => {
    await page.goto("/");
    // WebSocket 연결 확인
    const wsConnected = await page.evaluate(() => {
      return new Promise<boolean>((resolve) => {
        const ws = new WebSocket("ws://localhost:3000/__hmr");
        ws.onopen = () => resolve(true);
        ws.onerror = () => resolve(false);
        setTimeout(() => resolve(false), 3000);
      });
    });
    expect(wsConnected).toBe(true);
  });
});
