import { spawn } from "bun";
import { mkdtemp, rm, writeFile, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

/** ZTS 바이너리 경로 (프로젝트 루트 기준) */
const PROJECT_ROOT = resolve(import.meta.dir, "../../..");
export const ZTS_BIN = join(PROJECT_ROOT, "zig-out/bin/zts");

/** 임시 디렉토리를 생성하고 테스트 파일을 배치한 뒤, 정리 함수를 반환 */
export async function createFixture(
  files: Record<string, string>,
): Promise<{ dir: string; cleanup: () => Promise<void> }> {
  const dir = await mkdtemp(join(tmpdir(), "zts-integration-"));

  for (const [name, content] of Object.entries(files)) {
    const filePath = join(dir, name);
    const fileDir = join(filePath, "..");
    await mkdir(fileDir, { recursive: true });
    await writeFile(filePath, content);
  }

  return {
    dir,
    cleanup: () => rm(dir, { recursive: true, force: true }),
  };
}

/** ZTS CLI를 실행하고 stdout/stderr/exitCode를 반환 */
export async function runZts(
  args: string[],
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const proc = spawn({
    cmd: [ZTS_BIN, ...args],
    stdout: "pipe",
    stderr: "pipe",
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  return { stdout, stderr, exitCode };
}

/** ZTS 번들을 실행하고 번들링 + Node 실행 결과를 반환 */
export async function bundleAndRun(
  files: Record<string, string>,
  entry: string = "index.ts",
  extraArgs: string[] = [],
): Promise<{
  bundleOutput: string;
  runOutput: string;
  exitCode: number;
  cleanup: () => Promise<void>;
}> {
  const { dir, cleanup } = await createFixture(files);
  const outFile = join(dir, "out.js");

  // 번들
  const bundle = await runZts([
    "--bundle",
    join(dir, entry),
    "-o",
    outFile,
    ...extraArgs,
  ]);

  if (bundle.exitCode !== 0) {
    throw new Error(`ZTS bundle failed: ${bundle.stderr}`);
  }

  // 번들 결과 실행
  const run = spawn({
    cmd: ["bun", "run", outFile],
    stdout: "pipe",
    stderr: "pipe",
  });

  const [runOutput, runStderr, exitCode] = await Promise.all([
    new Response(run.stdout).text(),
    new Response(run.stderr).text(),
    run.exited,
  ]);

  return {
    bundleOutput: bundle.stdout,
    runOutput: runOutput.trim(),
    exitCode,
    cleanup,
  };
}
