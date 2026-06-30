import { execFile } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(__dirname, "../..");

const EXPECTED_OUTPUT = Object.freeze([2, 4, 6, 8, 10, 12, 14, 16]);
const EXPECTED_WGSL_SHA256 = "f03b12ba1e7df16b58babac43b326771a30d3e7de9278bfcd3daa8d95faf80b2";
const EXPECTED_INPUT_SHA256 = "af7de0621354bafceb193edf0fcf5d421cf21de7146580062fff53c7907f54e5";
const EXPECTED_OUTPUT_SHA256 = "9d42cad41af4aaf3ae973e5a48d96f61e4708edc57bf7dd29a497ebd96f506cf";

function isDeviceUnavailableOutput(text) {
  return (
    text.includes("not found") ||
    text.includes("unavailable") ||
    text.includes("No adapter") ||
    text.includes("no adapter") ||
    text.includes("not supported") ||
    text.includes("ENOENT") ||
    text.includes("Could not load")
  );
}

function run(command, args) {
  return new Promise((resolve) => {
    execFile(
      command,
      args,
      {
        cwd: packageRoot,
        env: process.env,
        maxBuffer: 1024 * 1024,
      },
      (error, stdout, stderr) => {
        resolve({
          code: error?.code ?? 0,
          signal: error?.signal ?? null,
          stdout: stdout ?? "",
          stderr: stderr ?? "",
        });
      },
    );
  });
}

export async function runFirstKernelReceiptTest({ runtimeHost, command, exampleFile }) {
  let passed = 0;
  let failed = 0;
  let skipped = 0;

  function check(label, condition, detail) {
    if (condition) {
      passed += 1;
      console.log(`  ok: ${label}`);
    } else {
      failed += 1;
      console.error(`  FAIL: ${label}${detail ? " -- " + detail : ""}`);
    }
  }

  function skip(label) {
    skipped += 1;
    console.log(`  SKIP: ${label}`);
  }

  console.log(`=== doe-gpu integration: ${runtimeHost} first-kernel receipt ===\n`);

  const result = await run(command, [exampleFile]);
  if (result.code !== 0) {
    const output = `${result.stdout}\n${result.stderr}`;
    if (isDeviceUnavailableOutput(output)) {
      skip(`${runtimeHost} first-kernel example (no GPU available)`);
      console.log(`\nResults: ${passed} passed, ${failed} failed, ${skipped} skipped`);
      return;
    }
    check(
      `${runtimeHost} first-kernel example exits 0`,
      false,
      `exit=${result.code}${result.signal ? ` signal=${result.signal}` : ""}\n${output.trim()}`,
    );
    console.log(`\nResults: ${passed} passed, ${failed} failed, ${skipped} skipped`);
    process.exitCode = 1;
    return;
  }

  check(`${runtimeHost} first-kernel example writes stderr-free receipt`, result.stderr.trim() === "", result.stderr.trim());

  let receipt = null;
  try {
    receipt = JSON.parse(result.stdout);
    check(`${runtimeHost} first-kernel receipt parses as JSON`, true);
  } catch (error) {
    check(`${runtimeHost} first-kernel receipt parses as JSON`, false, error.message);
  }

  if (receipt) {
    check("receipt kind", receipt.kind === "doe-gpu.first-kernel.receipt", receipt.kind);
    check("receipt schema version", receipt.schemaVersion === 1, String(receipt.schemaVersion));
    check("runtime host", receipt.runtimeHost === runtimeHost, receipt.runtimeHost);
    check("provider module", receipt.provider?.module === "doe-gpu", JSON.stringify(receipt.provider));
    check("provider loaded", receipt.provider?.loaded === true, JSON.stringify(receipt.provider));
    check("provider uses Doe native runtime", receipt.provider?.doeNative === true, JSON.stringify(receipt.provider));
    check(
      "provider exposes native fast-path identity",
      receipt.provider?.nativeFastPaths != null && typeof receipt.provider.nativeFastPaths === "object",
      JSON.stringify(receipt.provider),
    );
    check("workload id", receipt.workload?.id === "vector-scale-f32", receipt.workload?.id);
    check("workload element count", receipt.workload?.elementCount === EXPECTED_OUTPUT.length, String(receipt.workload?.elementCount));
    check("WGSL hash", receipt.workload?.wgslSha256 === EXPECTED_WGSL_SHA256, receipt.workload?.wgslSha256);
    check("input hash", receipt.workload?.inputSha256 === EXPECTED_INPUT_SHA256, receipt.workload?.inputSha256);
    check(
      "output values",
      Array.isArray(receipt.result?.output) &&
        receipt.result.output.length === EXPECTED_OUTPUT.length &&
        receipt.result.output.every((value, index) => Object.is(value, EXPECTED_OUTPUT[index])),
      JSON.stringify(receipt.result?.output),
    );
    check("output hash", receipt.result?.outputSha256 === EXPECTED_OUTPUT_SHA256, receipt.result?.outputSha256);
    check(
      "duration is finite",
      Number.isFinite(receipt.result?.durationMs) && receipt.result.durationMs >= 0,
      String(receipt.result?.durationMs),
    );
  }

  console.log(`\nResults: ${passed} passed, ${failed} failed, ${skipped} skipped`);
  process.exitCode = failed > 0 ? 1 : 0;
}
