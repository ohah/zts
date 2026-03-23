#!/usr/bin/env bun
/**
 * ZTS Smoke Test — 실제 프로젝트 빌드 검증
 *
 * npm에서 실제 라이브러리를 설치하고 ZTS로 번들링하여
 * 1) 빌드 성공 여부  2) 출력 크기  3) esbuild 대비 비교
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync, existsSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../..");
const ZTS_BIN = join(ROOT, "zig-out/bin/zts");
const ESBUILD_BIN = join(__dirname, "node_modules/.bin/esbuild");

interface SmokeResult {
  project: string;
  ztsBuild: boolean;
  ztsSize: number;
  ztsTime: number;
  esbuildBuild: boolean;
  esbuildSize: number;
  esbuildTime: number;
  errors: string[];
}

function exec(
  bin: string,
  args: string[],
  cwd?: string,
): { ok: boolean; stderr: string; time: number } {
  const start = performance.now();
  const r = spawnSync(bin, args, { cwd, stdio: "pipe", timeout: 60000 });
  const time = Math.round(performance.now() - start);
  const stderr = r.stderr?.toString() ?? "";
  return { ok: r.status === 0, stderr, time };
}

function fileSize(path: string): number {
  try {
    return statSync(path).size;
  } catch {
    return 0;
  }
}

function testProject(name: string, npmPkg: string, entryCode: string): SmokeResult {
  const dir = mkdtempSync(join(tmpdir(), `zts-smoke-${name}-`));
  const result: SmokeResult = {
    project: name,
    ztsBuild: false,
    ztsSize: 0,
    ztsTime: 0,
    esbuildBuild: false,
    esbuildSize: 0,
    esbuildTime: 0,
    errors: [],
  };

  try {
    // npm install
    writeFileSync(
      join(dir, "package.json"),
      JSON.stringify({ name: `smoke-${name}`, private: true }),
    );
    const install = spawnSync("npm", ["install", npmPkg, "--save"], {
      cwd: dir,
      stdio: "pipe",
      timeout: 60000,
    });
    if (install.status !== 0) {
      result.errors.push(`npm install failed: ${install.stderr?.toString().slice(0, 200)}`);
      return result;
    }

    // Entry file
    writeFileSync(join(dir, "index.ts"), entryCode);

    const ztsOut = join(dir, "dist-zts.js");
    const esOut = join(dir, "dist-esbuild.js");

    // ZTS bundle
    const zts = exec(ZTS_BIN, ["--bundle", join(dir, "index.ts"), "-o", ztsOut, "--platform=node"]);
    result.ztsBuild = zts.ok;
    result.ztsSize = fileSize(ztsOut);
    result.ztsTime = zts.time;
    if (!zts.ok) {
      result.errors.push(`ZTS build: ${zts.stderr.slice(0, 500)}`);
    }

    // ZTS 실행 검증
    if (zts.ok) {
      const run = exec("node", [ztsOut]);
      if (!run.ok) {
        result.ztsBuild = false; // 실행 실패 = 빌드 실패로 간주
        result.errors.push(`ZTS run: ${run.stderr.slice(0, 300)}`);
      }
    }

    // esbuild bundle (baseline)
    if (existsSync(ESBUILD_BIN)) {
      const es = exec(ESBUILD_BIN, [
        join(dir, "index.ts"),
        "--bundle",
        `--outfile=${esOut}`,
        "--minify",
        "--loader:.ts=ts",
        "--platform=node",
      ]);
      result.esbuildBuild = es.ok;
      result.esbuildSize = fileSize(esOut);
      result.esbuildTime = es.time;
    }
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }

  return result;
}

// ============================================================
// Test cases
// ============================================================

const projects = [
  {
    name: "lodash-es",
    pkg: "lodash-es",
    entry: `import { groupBy, sortBy, uniq } from 'lodash-es';\nconsole.log(groupBy, sortBy, uniq);`,
  },
  {
    name: "preact",
    pkg: "preact",
    entry: `import { h, render } from 'preact';\nconsole.log(h, render);`,
  },
  {
    name: "date-fns",
    pkg: "date-fns",
    entry: `import { format, addDays } from 'date-fns';\nconsole.log(format(addDays(new Date(), 1), 'yyyy-MM-dd'));`,
  },
  {
    name: "uuid",
    pkg: "uuid",
    entry: `import { v4 } from 'uuid';\nconsole.log(v4());`,
  },
  {
    name: "zod",
    pkg: "zod",
    entry: `import { z } from 'zod';\nconst schema = z.string().email();\nconsole.log(schema.parse('test@test.com'));`,
  },
];

// ============================================================
// Run
// ============================================================

console.log("ZTS Smoke Test — Real Project Bundling\n");

const results: SmokeResult[] = [];

for (const p of projects) {
  process.stdout.write(`Testing ${p.name}... `);
  const r = testProject(p.name, p.pkg, p.entry);
  results.push(r);

  const status = r.ztsBuild ? "OK" : "FAIL";
  const sizeKB = r.ztsSize > 0 ? `${Math.round(r.ztsSize / 1024)}KB` : "-";
  console.log(`${status} (${sizeKB}, ${r.ztsTime}ms)`);

  if (r.errors.length > 0) {
    for (const e of r.errors) {
      console.log(`  ERROR: ${e.slice(0, 200)}`);
    }
  }
}

// Summary table
console.log("\n### Smoke Test Results\n");
console.log("| Project | ZTS | ZTS Size | ZTS Time | esbuild | esbuild Size | esbuild Time |");
console.log("|---------|-----|----------|----------|---------|--------------|--------------|");
for (const r of results) {
  const zStatus = r.ztsBuild ? "OK" : "FAIL";
  const eStatus = r.esbuildBuild ? "OK" : "FAIL";
  const zSize = r.ztsSize > 0 ? `${Math.round(r.ztsSize / 1024)}KB` : "-";
  const eSize = r.esbuildSize > 0 ? `${Math.round(r.esbuildSize / 1024)}KB` : "-";
  console.log(
    `| ${r.project} | ${zStatus} | ${zSize} | ${r.ztsTime}ms | ${eStatus} | ${eSize} | ${r.esbuildTime}ms |`,
  );
}

const passed = results.filter((r) => r.ztsBuild).length;
const total = results.length;
console.log(`\n${passed}/${total} projects built successfully.`);

if (passed < total) {
  process.exit(1);
}
