import { execFile } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(here, "../..");
const example = join(packageRoot, "examples/node-governed-first-kernel.mjs");

function execute() {
  return new Promise((resolve) => {
    execFile(process.execPath, [example], {
      cwd: packageRoot,
      env: process.env,
      maxBuffer: 1024 * 1024,
    }, (error, stdout, stderr) => resolve({
      code: error?.code ?? 0,
      signal: error?.signal ?? null,
      stdout: stdout ?? "",
      stderr: stderr ?? "",
    }));
  });
}

const result = await execute();
if (result.code !== 0) {
  const diagnostic = `${result.stdout}\n${result.stderr}`;
  if (/unavailable|not found|No adapter|no adapter|not supported|ENOENT|Could not load/i.test(diagnostic)) {
    console.log("governed first-kernel integration: skipped (GPU unavailable)");
  } else {
    console.error(diagnostic);
    process.exitCode = 1;
  }
} else {
  const receipt = JSON.parse(result.stdout);
  const expected = [2, 4, 6, 8, 10, 12, 14, 16];
  const pass = receipt.ok === true
    && receipt.receipt?.schema === "doe.governed-node-webgpu-receipt/v1"
    && receipt.receipt?.oracle?.status === "pass"
    && receipt.receipt?.lifecycle?.status === "release-complete"
    && receipt.receipt?.lifecycle?.globalsRestored === true
    && receipt.output?.every((value, index) => Object.is(value, expected[index]));
  if (!pass) {
    console.error(result.stdout);
    process.exitCode = 1;
  } else {
    console.log("governed first-kernel integration: ok");
  }
}
