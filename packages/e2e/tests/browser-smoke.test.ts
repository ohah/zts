import { test, expect } from "@playwright/test";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, writeFile, mkdir, readFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join, resolve, extname } from "node:path";

const ZTS_BIN = resolve(__dirname, "../../../zig-out/bin/zts");

interface BrowserSmokeCase {
  name: string;
  pkg: string;
  entry: string;
  expected: string;
  extraArgs?: string[];
}

/**
 * 브라우저 스모크 테스트 — ZTS로 --platform=browser 번들링 후
 * Playwright에서 실제 브라우저로 실행하여 console.log 출력 검증.
 *
 * Node.js 전용 패키지(express, jsonwebtoken 등)는 제외.
 * process.env.NODE_ENV를 참조하는 패키지는 --define으로 치환.
 */
const cases: BrowserSmokeCase[] = [
  {
    name: "lodash-es",
    pkg: "lodash-es",
    entry: `import { uniq } from 'lodash-es';\nconsole.log(JSON.stringify(uniq([1,2,2,3])));`,
    expected: "[1,2,3]",
  },
  {
    name: "preact",
    pkg: "preact",
    entry: `import { h } from 'preact';\nconsole.log(typeof h);`,
    expected: "function",
  },
  {
    name: "immer",
    pkg: "immer",
    entry: `import { produce } from 'immer';\nconst n = produce({ a: 1 }, d => { d.a = 2; });\nconsole.log(n.a);`,
    expected: "2",
    extraArgs: ['--define:process.env.NODE_ENV="production"'],
  },
  {
    name: "mobx",
    pkg: "mobx",
    entry: `import { observable } from 'mobx';\nconst o = observable({ v: 0 });\no.v = 42;\nconsole.log(o.v);`,
    expected: "42",
    extraArgs: ['--define:process.env.NODE_ENV="production"'],
  },
  {
    name: "clsx",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b'));`,
    expected: "a b",
  },
  {
    name: "ms",
    pkg: "ms",
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'));`,
    expected: "172800000",
  },
  {
    name: "eventemitter3",
    pkg: "eventemitter3",
    entry: `import EE from 'eventemitter3';\nconst e = new EE();\nlet v = 0;\ne.on('x', (n) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
    expected: "42",
  },
  {
    name: "three",
    pkg: "three",
    entry: `import { Vector3 } from 'three';\nconst v = new Vector3(1, 2, 3);\nconsole.log(v.length().toFixed(2));`,
    expected: "3.74",
  },
  {
    name: "dayjs",
    pkg: "dayjs",
    entry: `import dayjs from 'dayjs';\nconsole.log(dayjs('2024-01-01').format('YYYY/MM/DD'));`,
    expected: "2024/01/01",
  },
  {
    name: "nanoid",
    pkg: "nanoid",
    entry: `import { nanoid } from 'nanoid';\nconsole.log(nanoid().length >= 21);`,
    expected: "true",
  },
  {
    name: "zod",
    pkg: "zod",
    entry: `import { z } from 'zod';\nconsole.log(typeof z.string);`,
    expected: "function",
  },
  {
    name: "superjson",
    pkg: "superjson",
    entry: `import superjson from 'superjson';\nconsole.log(typeof superjson.stringify);`,
    expected: "function",
  },
  {
    name: "date-fns",
    pkg: "date-fns",
    entry: `import { addDays } from 'date-fns';\nconsole.log(typeof addDays);`,
    expected: "function",
  },
  {
    name: "d3",
    pkg: "d3",
    entry: `import { scaleLinear } from 'd3';\nconsole.log(scaleLinear().domain([0, 1]).range([0, 10])(0.5));`,
    expected: "5",
  },
  {
    name: "pako",
    pkg: "pako",
    entry: `import pako from 'pako';\nconsole.log(typeof pako.deflate);`,
    expected: "function",
  },
  {
    name: "solid-js",
    pkg: "solid-js",
    entry: `import { createSignal } from 'solid-js';\nconst [count, setCount] = createSignal(0);\nsetCount(1);\nconsole.log(count());`,
    expected: "1",
  },
  {
    name: "vue",
    pkg: "vue",
    entry: `import { ref } from 'vue';\nconsole.log(ref(0).value);`,
    expected: "0",
  },
  {
    name: "svelte",
    pkg: "svelte",
    entry: `import { readable } from 'svelte/store';\nlet v;\nreadable(42, s => { s(42); return () => {}; }).subscribe(x => v = x);\nconsole.log(v);`,
    expected: "42",
  },
  {
    name: "react",
    pkg: "react",
    entry: `import React from 'react';\nconsole.log(typeof React.createElement);`,
    expected: "function",
  },
  {
    name: "graphql",
    pkg: "graphql",
    entry: `import { parse } from 'graphql';\nconsole.log(parse('{ hello }').definitions.length);`,
    expected: "1",
  },
  {
    name: "uuid",
    pkg: "uuid",
    entry: `import { v4 } from 'uuid';\nconsole.log(typeof v4(), v4().length);`,
    expected: "string 36",
  },
  {
    name: "rxjs",
    pkg: "rxjs",
    entry: `import { of, map, toArray } from 'rxjs';\nof(1,2,3).pipe(map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
    expected: "[10,20,30]",
  },
  {
    name: "tiny-invariant",
    pkg: "tiny-invariant",
    entry: `import invariant from 'tiny-invariant';\ninvariant(true, 'ok');\nconsole.log('pass');`,
    expected: "pass",
    extraArgs: ['--define:process.env.NODE_ENV="production"'],
  },
  {
    name: "tanstack-query",
    pkg: "@tanstack/query-core",
    entry: `import { QueryClient } from '@tanstack/query-core';\nconst qc = new QueryClient();\nconsole.log(typeof qc.fetchQuery);`,
    expected: "function",
  },
  // effect: scope hoisting에서 "window" 글로벌 충돌 — deconflict 개선 후 추가
  // jotai, valtio: import.meta outside module — ESM 출력 또는 import.meta polyfill 필요
  // fp-ts: 동일 import.meta 이슈
  {
    name: "neverthrow",
    pkg: "neverthrow",
    entry: `import { ok } from 'neverthrow';\nconst r = ok(42).map(n => n + 1);\nconsole.log(r.isOk(), r._unsafeUnwrap());`,
    expected: "true 43",
  },
  {
    name: "yaml",
    pkg: "yaml",
    entry: `import { parse } from 'yaml';\nconsole.log(JSON.stringify(parse('a: 1\\nb: 2')));`,
    expected: '{"a":1,"b":2}',
  },
  {
    name: "semver",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0', '1.0.0'));`,
    expected: "true",
  },
  {
    name: "hono",
    pkg: "hono",
    entry: `import { Hono } from 'hono';\nconst app = new Hono();\napp.get('/', (c) => c.text('Hello'));\nconsole.log('routes:', app.routes.length);`,
    expected: "routes: 1",
  },
  {
    name: "chalk",
    pkg: "chalk@5",
    entry: `import chalk from 'chalk';\nconsole.log(typeof chalk.red);`,
    expected: "function",
  },
  {
    name: "drizzle-orm",
    pkg: "drizzle-orm",
    entry: `import { sql } from 'drizzle-orm';\nconsole.log(typeof sql);`,
    expected: "function",
  },
  {
    name: "react-dom",
    pkg: "react-dom@18 react@18",
    entry: `import { renderToString } from 'react-dom/server';\nimport { createElement } from 'react';\nconsole.log(renderToString(createElement('div', null, 'Hello')));`,
    expected: "<div>Hello</div>",
    extraArgs: ['--define:process.env.NODE_ENV="production"'],
  },
];

const MIME: Record<string, string> = {
  ".html": "text/html",
  ".js": "application/javascript",
};

function serve(dir: string): Promise<{ server: Server; port: number }> {
  return new Promise((res) => {
    const server = createServer(async (req, resp) => {
      const filePath = join(dir, req.url === "/" ? "index.html" : req.url!);
      try {
        const data = await readFile(filePath);
        resp.writeHead(200, { "Content-Type": MIME[extname(filePath)] ?? "text/plain" });
        resp.end(data);
      } catch {
        resp.writeHead(404);
        resp.end("Not Found");
      }
    });
    server.listen(0, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      res({ server, port });
    });
  });
}

let fixtureDir: string;

test.beforeAll(async () => {
  fixtureDir = await mkdtemp(join(tmpdir(), "zts-browser-smoke-"));
});

test.afterAll(async () => {
  await rm(fixtureDir, { recursive: true, force: true });
});

for (const c of cases) {
  test(`browser: ${c.name}`, async ({ page }) => {
    const caseDir = join(fixtureDir, c.name);
    await mkdir(caseDir, { recursive: true });

    await writeFile(
      join(caseDir, "package.json"),
      JSON.stringify({ name: `bs-${c.name}`, private: true }),
    );
    const install = spawnSync("npm", ["install", ...c.pkg.split(/\s+/), "--save"], {
      cwd: caseDir,
      stdio: "pipe",
      timeout: 120000,
    });
    expect(
      install.status,
      `npm install ${c.pkg} failed: ${install.stderr?.toString().slice(0, 200)}`,
    ).toBe(0);

    await writeFile(join(caseDir, "index.ts"), c.entry);
    const outFile = join(caseDir, "bundle.js");
    const build = spawnSync(
      ZTS_BIN,
      [
        "--bundle",
        join(caseDir, "index.ts"),
        "-o",
        outFile,
        "--platform=browser",
        ...(c.extraArgs ?? []),
      ],
      { stdio: "pipe", timeout: 30000 },
    );
    expect(build.status, `ZTS build failed: ${build.stderr?.toString().slice(0, 300)}`).toBe(0);

    await writeFile(
      join(caseDir, "index.html"),
      `<!DOCTYPE html><html><body><script src="./bundle.js"></script></body></html>`,
    );

    const { server, port } = await serve(caseDir);
    try {
      const logs: string[] = [];
      page.on("console", (msg) => {
        if (msg.type() === "log") logs.push(msg.text());
      });

      const errors: string[] = [];
      page.on("pageerror", (err) => errors.push(err.message));

      await page.goto(`http://localhost:${port}/`);
      await page.waitForTimeout(1000);

      expect(errors, `Browser errors in ${c.name}: ${errors.join(", ")}`).toHaveLength(0);
      expect(logs.join("\n"), `Expected "${c.expected}" in console output`).toContain(c.expected);
    } finally {
      server.close();
    }
  });
}
