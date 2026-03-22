import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: "./tests",
  timeout: 30_000,
  retries: process.env.CI ? 2 : 0,
  use: {
    baseURL: "http://localhost:3000",
    trace: "on-first-retry",
  },
  /* dev server가 구현되면 활성화
  webServer: {
    command: "zts serve ./fixture",
    port: 3000,
    reuseExistingServer: !process.env.CI,
  },
  */
});
