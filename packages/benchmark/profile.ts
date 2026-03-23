#!/usr/bin/env bun
/**
 * ZTS Pipeline Profiler — 단계별 병목 측정
 *
 * 다양한 크기의 TS 파일에서 ZTS CLI를 실행하고
 * 파일 크기 대비 소요 시간의 스케일링 특성을 측정한다.
 */

import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ZTS_BIN = resolve(__dirname, "../../zig-out/bin/zts");
const ITERATIONS = 10;

function generateTS(lines: number): string {
  const parts: string[] = [];
  for (let i = 0; i < lines; i++) {
    parts.push(`export const value${i}: number = ${i};`);
    if (i % 100 === 0) {
      parts.push(`export function compute${i}(x: number): number { return x * ${i}; }`);
    }
  }
  return parts.join("\n");
}

function measure(inputFile: string, outFile: string): number {
  const times: number[] = [];
  for (let i = 0; i < ITERATIONS; i++) {
    const start = performance.now();
    spawnSync(ZTS_BIN, [inputFile, "-o", outFile], { stdio: "pipe", timeout: 30000 });
    times.push(performance.now() - start);
  }
  return Math.round(times.sort((a, b) => a - b)[Math.floor(ITERATIONS / 2)]); // median
}

console.log("ZTS Pipeline Profiler");
console.log(`  Iterations: ${ITERATIONS} (median)\n`);

const scales = [100, 500, 1000, 2000, 5000, 10000];
const dir = mkdtempSync(join(tmpdir(), "zts-profile-"));

console.log("| Lines | Size (KB) | Time (ms) | ms/1K lines |");
console.log("|-------|-----------|-----------|-------------|");

for (const lines of scales) {
  const source = generateTS(lines);
  const inputFile = join(dir, `input_${lines}.ts`);
  const outFile = join(dir, `output_${lines}.js`);
  writeFileSync(inputFile, source);

  const sizeKB = Math.round(source.length / 1024);
  const ms = measure(inputFile, outFile);
  const perK = (ms / (lines / 1000)).toFixed(1);

  console.log(`| ${lines} | ${sizeKB} | ${ms} | ${perK} |`);
}

rmSync(dir, { recursive: true, force: true });

console.log("\n(ms/1K lines가 일정하면 O(n), 증가하면 O(n²) 의심)");
