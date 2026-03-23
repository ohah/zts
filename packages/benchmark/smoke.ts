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

function testProject(
  name: string,
  npmPkg: string,
  entryCode: string,
  extraArgs: string[] = [],
): SmokeResult {
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
    const zts = exec(ZTS_BIN, [
      "--bundle",
      join(dir, "index.ts"),
      "-o",
      ztsOut,
      "--platform=node",
      ...extraArgs,
    ]);
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
  {
    name: "axios",
    pkg: "axios",
    entry: `import axios from 'axios';\nconsole.log(typeof axios.get, typeof axios.post, typeof axios.create);`,
  },
  {
    name: "toolkit",
    pkg: "@reduxjs/toolkit",
    entry: `import { configureStore, createSlice } from '@reduxjs/toolkit';\nconst slice = createSlice({ name: 'test', initialState: 0, reducers: { inc: s => s + 1 } });\nconsole.log(slice.name, typeof slice.reducer);`,
  },
  {
    name: "rxjs",
    pkg: "rxjs",
    entry: `import { of, map, filter, toArray } from 'rxjs';\nof(1,2,3,4,5).pipe(filter(x=>x%2===0), map(x=>x*10), toArray()).subscribe(arr=>console.log(JSON.stringify(arr)));`,
  },
  {
    name: "immer",
    pkg: "immer",
    entry: `import { produce } from 'immer';\nconst o = { a: 1, b: [1,2] };\nconst n = produce(o, d => { d.a = 2; d.b.push(3); });\nconsole.log(o.a, n.a, o === n);`,
  },
  {
    name: "superjson",
    pkg: "superjson",
    entry: `import superjson from 'superjson';\nconst d = { s: new Set([1,2]), m: new Map([['a',1]]) };\nconst r = superjson.parse(superjson.stringify(d)) as typeof d;\nconsole.log(r.s instanceof Set, r.m instanceof Map);`,
  },
  {
    name: "express",
    pkg: "express",
    entry: `import express from 'express';\nconst app = express();\napp.get('/t', (q,s)=>s.json({ok:true}));\nconsole.log(typeof app.listen, typeof app.get);`,
  },
  {
    name: "react",
    pkg: "react",
    entry: `import React from 'react';\nconst el = React.createElement('div', {id:'t'}, 'hi');\nconsole.log(el.type, el.props.id);`,
  },
  {
    name: "commander",
    pkg: "commander",
    entry: `import { Command } from 'commander';\nconst p = new Command();\np.option('-n, --name <str>', 'name').parse(['node', 'test', '--name', 'hello']);\nconsole.log(p.opts().name);`,
  },
  {
    name: "eventemitter3",
    pkg: "eventemitter3",
    entry: `import EE from 'eventemitter3';\nconst e = new EE();\nlet v = 0;\ne.on('x', (n: number) => v = n);\ne.emit('x', 42);\nconsole.log(v);`,
  },
  {
    name: "ms",
    pkg: "ms",
    entry: `import ms from 'ms';\nconsole.log(ms('2 days'), ms(60000));`,
  },
  {
    name: "dotenv",
    pkg: "dotenv",
    entry: `import dotenv from 'dotenv';\nconsole.log(typeof dotenv.config, typeof dotenv.parse);`,
  },
  {
    name: "jsonwebtoken",
    pkg: "jsonwebtoken",
    entry: `import jwt from 'jsonwebtoken';\nconst t = jwt.sign({uid:1},'secret');\nconst d = jwt.verify(t,'secret') as any;\nconsole.log(d.uid);`,
  },
  {
    name: "bcryptjs",
    pkg: "bcryptjs",
    entry: `import bcrypt from 'bcryptjs';\nconst h = bcrypt.hashSync('pw', 4);\nconsole.log(bcrypt.compareSync('pw', h));`,
  },
  {
    name: "clsx",
    pkg: "clsx",
    entry: `import { clsx } from 'clsx';\nconsole.log(clsx('a', false, 'b', {c:true, d:false}, ['e']));`,
  },
  {
    name: "tiny-invariant",
    pkg: "tiny-invariant",
    entry: `import invariant from 'tiny-invariant';\ninvariant(true, 'ok');\nconsole.log('pass');`,
  },
  {
    name: "tanstack-query",
    pkg: "@tanstack/query-core",
    entry: `import { QueryClient } from '@tanstack/query-core';\nconst qc = new QueryClient();\nqc.fetchQuery({queryKey:['t'],queryFn:()=>Promise.resolve(42)}).then(r=>{console.log(r);qc.clear();});`,
  },
  {
    name: "fast-glob",
    pkg: "fast-glob",
    entry: `import fg from 'fast-glob';\nconsole.log(typeof fg, typeof fg.sync);`,
  },
  {
    name: "micromatch",
    pkg: "micromatch",
    entry: `import mm from 'micromatch';\nconsole.log(mm(['foo.js','bar.ts','baz.js'], '*.js'));`,
  },
  {
    name: "semver",
    pkg: "semver",
    entry: `import semver from 'semver';\nconsole.log(semver.gt('2.0.0','1.0.0'), semver.valid('1.2.3'));`,
  },
  {
    name: "debug",
    pkg: "debug",
    entry: `import debug from 'debug';\nconst log = debug('test');\nconsole.log(typeof log);`,
  },
  {
    name: "chalk",
    pkg: "chalk@5",
    entry: `import chalk from 'chalk';\nconsole.log(chalk.red('hello'));`,
  },
  {
    name: "yaml",
    pkg: "yaml",
    entry: `import { parse } from 'yaml';\nconsole.log(JSON.stringify(parse('a: 1\\nb: 2')));`,
  },
  {
    name: "yargs",
    pkg: "yargs",
    entry: `import yargs from 'yargs';\nconsole.log(typeof yargs);`,
    extraArgs: ["--format=cjs"],
  },
  {
    name: "effect",
    pkg: "effect",
    entry: `import { Effect, pipe } from 'effect';\nconst p = pipe(Effect.succeed(42), Effect.map((n: number) => n + 1));\nEffect.runPromise(p).then(r => console.log(r));`,
  },
];

// ============================================================
// Run
// ============================================================

console.log("ZTS Smoke Test — Real Project Bundling\n");

const results: SmokeResult[] = [];

for (const p of projects) {
  process.stdout.write(`Testing ${p.name}... `);
  const r = testProject(p.name, p.pkg, p.entry, (p as any).extraArgs);
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
