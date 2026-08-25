// Exact-output Cloudflare Kitesurf CDP executor for K0 shared tasks.

import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(SCRIPT_DIR, "../../..");

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      throw new Error("K0 CDP arguments must be key-value pairs");
    }
    values[key.slice(2)] = value;
  }
  if (!["cdp-navigation", "cdp-automation"].includes(values.action)) {
    throw new Error("K0 CDP action is unsupported");
  }
  if (!values["binding-json"]) {
    throw new Error("K0 CDP binding JSON is required");
  }
  return {
    action: values.action,
    binding: JSON.parse(values["binding-json"]),
  };
}

function canonicalize(value) {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.keys(value).sort().map((key) => [key, canonicalize(value[key])]),
    );
  }
  return value;
}

function loadPlaywright() {
  const require = createRequire(import.meta.url);
  const candidates = [
    path.join(REPO_ROOT, "browser/chromium/node_modules/playwright-core"),
    "playwright-core",
    "playwright",
  ];
  for (const candidate of candidates) {
    try {
      return require(candidate);
    } catch (error) {
      if (error?.code !== "MODULE_NOT_FOUND") throw error;
    }
  }
  throw new Error("playwright-core is required for K0 CDP execution");
}

async function observationValue(locator, observation) {
  if (observation.property === "textContent") return locator.textContent();
  if (observation.property === "value") return locator.inputValue();
  if (observation.property === "checked") return locator.isChecked();
  if (observation.property === "disabled") return locator.isDisabled();
  if (observation.property === "attribute") {
    if (!observation.attribute) {
      throw new Error("attribute observation requires attribute name");
    }
    return locator.getAttribute(observation.attribute);
  }
  throw new Error("unsupported observation property");
}

async function applyStep(page, step) {
  const locator = page.locator(step.selector).first();
  if (step.action === "click") {
    await locator.click();
    return;
  }
  if (step.action === "fill") {
    if (typeof step.value !== "string") {
      throw new Error("fill step requires a string value");
    }
    await locator.fill(step.value);
    return;
  }
  throw new Error("unsupported K0 automation step");
}

async function main() {
  const { action, binding } = parseArgs(process.argv.slice(2));
  const accountId = process.env.K0_CLOUDFLARE_ACCOUNT_ID;
  const apiToken = process.env.K0_CLOUDFLARE_API_TOKEN;
  const cdpPath = process.env.K0_CLOUDFLARE_CDP_PATH;
  if (!accountId || !apiToken || !cdpPath) {
    throw new Error("K0 CDP credentials and path are required");
  }
  const endpoint = `wss://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(accountId)}/${cdpPath}?browser=kitesurf`;
  const { chromium } = loadPlaywright();
  const browser = await chromium.connectOverCDP(endpoint, {
    headers: { Authorization: `Bearer ${apiToken}` },
  });
  try {
    const context = browser.contexts()[0] || await browser.newContext();
    const page = await context.newPage();
    await page.goto(binding.url, { waitUntil: "domcontentloaded" });
    if (action === "cdp-automation") {
      for (const step of binding.steps || []) await applyStep(page, step);
    }
    const observations = {};
    for (const observation of binding.observations || []) {
      observations[observation.id] = await observationValue(
        page.locator(observation.selector).first(),
        observation,
      );
    }
    const output = canonicalize({
      finalUrl: page.url(),
      observations,
      title: await page.title(),
    });
    process.stdout.write(JSON.stringify(output));
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  process.stderr.write(String(error?.stack || error));
  process.exitCode = 1;
});
