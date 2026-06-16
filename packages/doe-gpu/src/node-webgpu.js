// doe-gpu/node-webgpu - explicit Node WebGPU provider bootstrap.

import { existsSync, readFileSync, statSync } from 'node:fs';
import { isAbsolute, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const DEFAULT_PROVIDER_CREATE_ARGS = Object.freeze([
  'enable-dawn-features=allow_unsafe_apis',
]);
const DEFAULT_WEBGPU_PROVIDER_SPECIFIERS = Object.freeze([
  new URL('./native.js', import.meta.url).href,
  'webgpu',
]);
const ADAPTER_PROBE_OPTIONS = Object.freeze([
  { powerPreference: 'high-performance' },
  { powerPreference: 'low-power' },
  null,
]);
const PROVIDER_FAILURE_REASONS = Object.freeze([
  'native_webgpu_unavailable',
  'native_addon_unavailable',
  'runtime_library_unavailable',
  'provider_unavailable',
  'adapter_unavailable',
  'provider_import_failed',
  'unsupported_runtime_host',
  'runner_error',
]);
const PROVIDER_FAILURE_REASON_SET = new Set(PROVIDER_FAILURE_REASONS);

function normalizeProviderFailureReason(reason) {
  return PROVIDER_FAILURE_REASON_SET.has(reason) ? reason : 'runner_error';
}

function providerAvailabilityFailure({
  reason,
  provider = '',
  stage = '',
  detail = '',
}) {
  return Object.freeze({
    ok: false,
    reason: normalizeProviderFailureReason(reason),
    provider,
    stage,
    detail: String(detail ?? ''),
  });
}

function attachProviderAvailability(error, failure) {
  if (!error || !failure) {
    return error;
  }
  error.providerAvailability = failure;
  error.providerFailureReason = failure.reason;
  return error;
}

export function hasNavigatorGpu() {
  return typeof globalThis.navigator !== 'undefined'
    && !!globalThis.navigator?.gpu
    && typeof globalThis.navigator.gpu.requestAdapter === 'function';
}

export function hasGpuEnums() {
  return typeof globalThis.GPUBufferUsage !== 'undefined'
    && typeof globalThis.GPUShaderStage !== 'undefined'
    && typeof globalThis.GPUMapMode !== 'undefined'
    && typeof globalThis.GPUTextureUsage !== 'undefined';
}

function setGlobalIfMissing(name, value) {
  if (value === undefined || value === null) return;
  if (globalThis[name] !== undefined) return;
  Object.defineProperty(globalThis, name, {
    value,
    writable: true,
    configurable: true,
    enumerable: false,
  });
}

function installGlobalsFromModule(mod) {
  const globals = mod?.globals || mod?.default?.globals;
  if (!globals || typeof globals !== 'object') return;
  for (const [name, value] of Object.entries(globals)) {
    setGlobalIfMissing(name, value);
  }
}

function resolveExportsPath(exportsField, rootPath) {
  if (!exportsField) return null;
  if (typeof exportsField === 'string') {
    const candidate = resolve(rootPath, exportsField);
    return existsSync(candidate) ? candidate : null;
  }
  if (typeof exportsField !== 'object' || Array.isArray(exportsField)) {
    return null;
  }

  const nodeWebgpu = exportsField['./node-webgpu'];
  if (typeof nodeWebgpu === 'string') {
    const nodeWebgpuPath = resolve(rootPath, nodeWebgpu);
    if (existsSync(nodeWebgpuPath)) return nodeWebgpuPath;
  } else if (nodeWebgpu && typeof nodeWebgpu === 'object') {
    const preferred = nodeWebgpu.default || nodeWebgpu.node || nodeWebgpu.import;
    if (typeof preferred === 'string') {
      const preferredPath = resolve(rootPath, preferred);
      if (existsSync(preferredPath)) return preferredPath;
    }
  }

  const dot = exportsField['.'];
  if (typeof dot === 'string') {
    const dotPath = resolve(rootPath, dot);
    if (existsSync(dotPath)) return dotPath;
  } else if (dot && typeof dot === 'object') {
    const preferred = dot.default || dot.node || dot.import;
    if (typeof preferred === 'string') {
      const preferredPath = resolve(rootPath, preferred);
      if (existsSync(preferredPath)) return preferredPath;
    }
  }
  return null;
}

function resolveNodeModuleFilePath(candidatePath) {
  if (!existsSync(candidatePath)) return null;
  const stat = statSync(candidatePath);
  if (stat.isFile()) return candidatePath;
  if (!stat.isDirectory()) return null;

  const packageJsonPath = resolve(candidatePath, 'package.json');
  if (existsSync(packageJsonPath)) {
    try {
      const pkg = JSON.parse(readFileSync(packageJsonPath, 'utf8'));
      const exportedPath = resolveExportsPath(pkg.exports, candidatePath);
      if (exportedPath) return exportedPath;
      if (typeof pkg.main === 'string' && pkg.main.trim()) {
        const mainPath = resolve(candidatePath, pkg.main);
        if (existsSync(mainPath)) return mainPath;
      }
    } catch {
      // Malformed package metadata should not hide the fallback probes.
    }
  }

  const fallbackPaths = [
    resolve(candidatePath, 'src/node-webgpu.js'),
    resolve(candidatePath, 'index.js'),
    resolve(candidatePath, 'src/index.js'),
  ];
  for (const fallbackPath of fallbackPaths) {
    if (existsSync(fallbackPath)) return fallbackPath;
  }
  return null;
}

function looksLikePathSpecifier(candidate) {
  if (candidate.startsWith('.') || candidate.startsWith('/')) return true;
  if (candidate.startsWith('file://')) return true;
  const cwdRelative = resolve(process.cwd(), candidate);
  return candidate.includes('/') && existsSync(cwdRelative);
}

function resolveCandidateModuleSpecifier(candidate) {
  if (candidate.startsWith('file://')) return candidate;
  if (looksLikePathSpecifier(candidate)) {
    const normalizedPath = isAbsolute(candidate)
      ? candidate
      : resolve(process.cwd(), candidate);
    const resolvedFilePath = resolveNodeModuleFilePath(normalizedPath);
    if (resolvedFilePath) return pathToFileURL(resolvedFilePath).href;
  }
  return candidate;
}

function resolveExplicitWebgpuModuleSpecifier() {
  const fromEnv = process.env.DOE_NODE_WEBGPU_MODULE;
  if (typeof fromEnv === 'string' && fromEnv.trim().length > 0) {
    return resolveCandidateModuleSpecifier(fromEnv.trim());
  }
  return null;
}

function resolveGpuFromModule(mod) {
  if (!mod) return null;

  const fromModule = mod.gpu || mod.webgpu || mod.default?.gpu || mod.default?.webgpu;
  if (fromModule && typeof fromModule.requestAdapter === 'function') {
    return fromModule;
  }

  const tryCreateFactory = (factory) => {
    if (typeof factory !== 'function') return null;
    try {
      return factory([...DEFAULT_PROVIDER_CREATE_ARGS]);
    } catch {
      try {
        return factory([]);
      } catch {
        try {
          return factory();
        } catch {
          return null;
        }
      }
    }
  };

  const instanceFactory = mod.createInstance || mod.default?.createInstance;
  const createdFromInstanceFactory = tryCreateFactory(instanceFactory);
  if (createdFromInstanceFactory) {
    if (typeof createdFromInstanceFactory.requestAdapter === 'function') {
      return createdFromInstanceFactory;
    }
    if (createdFromInstanceFactory.gpu && typeof createdFromInstanceFactory.gpu.requestAdapter === 'function') {
      return createdFromInstanceFactory.gpu;
    }
  }

  const factory = mod.create || mod.default?.create;
  const created = tryCreateFactory(factory);
  if (created) {
    if (typeof created.requestAdapter === 'function') return created;
    if (created.gpu && typeof created.gpu.requestAdapter === 'function') {
      return created.gpu;
    }
  }

  if (mod.default && typeof mod.default.requestAdapter === 'function') {
    return mod.default;
  }
  return null;
}

export function installNavigatorGpu(gpu, options = {}) {
  if (!gpu || typeof gpu.requestAdapter !== 'function') return false;
  if (typeof globalThis.navigator === 'undefined') {
    Object.defineProperty(globalThis, 'navigator', {
      value: { gpu },
      writable: true,
      configurable: true,
      enumerable: false,
    });
    return true;
  }

  if (!globalThis.navigator.gpu || options.force === true) {
    Object.defineProperty(globalThis.navigator, 'gpu', {
      value: gpu,
      writable: true,
      configurable: true,
      enumerable: false,
    });
  }
  return true;
}

function installWebgpuFromModule(mod, options = {}) {
  const gpu = resolveGpuFromModule(mod);
  if (!installNavigatorGpu(gpu, options)) return false;

  installGlobalsFromModule(mod);
  setGlobalIfMissing('GPUBufferUsage', mod.GPUBufferUsage || mod.default?.GPUBufferUsage || mod.globals?.GPUBufferUsage);
  setGlobalIfMissing('GPUShaderStage', mod.GPUShaderStage || mod.default?.GPUShaderStage || mod.globals?.GPUShaderStage);
  setGlobalIfMissing('GPUMapMode', mod.GPUMapMode || mod.default?.GPUMapMode || mod.globals?.GPUMapMode);
  setGlobalIfMissing('GPUTextureUsage', mod.GPUTextureUsage || mod.default?.GPUTextureUsage || mod.globals?.GPUTextureUsage);

  return hasNavigatorGpu() && hasGpuEnums();
}

function formatAdapterProbeDetail(error) {
  if (!error) {
    return 'requestAdapter returned null for high-performance, low-power, and default options.';
  }
  const message = error?.message || String(error);
  return `requestAdapter failed: ${message}`;
}

async function probeInstalledGpuAdapter() {
  if (!hasNavigatorGpu()) {
    const detail = 'navigator.gpu.requestAdapter is unavailable after provider installation.';
    return {
      ok: false,
      detail,
      failure: providerAvailabilityFailure({
        reason: 'native_webgpu_unavailable',
        stage: 'probeInstalledGpuAdapter',
        detail,
      }),
    };
  }
  if (!hasGpuEnums()) {
    const detail = 'WebGPU enum globals are unavailable after provider installation.';
    return {
      ok: false,
      detail,
      failure: providerAvailabilityFailure({
        reason: 'native_webgpu_unavailable',
        stage: 'probeInstalledGpuAdapter',
        detail,
      }),
    };
  }

  let lastError = null;
  for (const adapterOptions of ADAPTER_PROBE_OPTIONS) {
    try {
      const adapter = adapterOptions
        ? await globalThis.navigator.gpu.requestAdapter(adapterOptions)
        : await globalThis.navigator.gpu.requestAdapter();
      if (adapter) return { ok: true, detail: null };
    } catch (error) {
      lastError = error;
    }
  }

  const detail = formatAdapterProbeDetail(lastError);
  return {
    ok: false,
    detail,
    failure: providerAvailabilityFailure({
      reason: 'adapter_unavailable',
      stage: 'probeInstalledGpuAdapter',
      detail,
    }),
  };
}

async function tryInstallAndProbeProvider(providerSpecifier, options = {}) {
  const specifier = resolveCandidateModuleSpecifier(providerSpecifier);
  let mod;
  try {
    mod = await import(specifier);
  } catch (error) {
    const detail = `import failed: ${error?.message || String(error)}`;
    return {
      ok: false,
      provider: providerSpecifier,
      detail,
      failure: providerAvailabilityFailure({
        reason: 'provider_import_failed',
        provider: providerSpecifier,
        stage: 'provider.import',
        detail,
      }),
      module: null,
    };
  }

  if (!installWebgpuFromModule(mod, { force: options.force === true })) {
    const detail = 'failed to install WebGPU provider globals.';
    return {
      ok: false,
      provider: providerSpecifier,
      detail,
      failure: providerAvailabilityFailure({
        reason: 'native_webgpu_unavailable',
        provider: providerSpecifier,
        stage: 'provider.installGlobals',
        detail,
      }),
      module: mod,
    };
  }

  const probe = await probeInstalledGpuAdapter();
  if (!probe.ok) {
    return {
      ok: false,
      provider: providerSpecifier,
      detail: probe.detail,
      failure: providerAvailabilityFailure({
        reason: probe.failure?.reason ?? 'adapter_unavailable',
        provider: providerSpecifier,
        stage: probe.failure?.stage ?? 'provider.probeAdapter',
        detail: probe.detail,
      }),
      module: mod,
    };
  }

  return {
    ok: true,
    provider: providerSpecifier,
    detail: null,
    module: mod,
  };
}

export async function bootstrapNodeWebGPUProvider(providerSpecifier, options = {}) {
  const attempt = await tryInstallAndProbeProvider(providerSpecifier, {
    force: options.force === true,
  });
  if (!attempt.ok) {
    throw attachProviderAvailability(
      new Error(
        `failed to install Doe Node WebGPU provider "${providerSpecifier}": ${attempt.detail}`,
      ),
      attempt.failure,
    );
  }
  return {
    ok: true,
    provider: providerSpecifier,
    module: attempt.module,
  };
}

export async function bootstrapNodeWebGPU() {
  const explicitSpecifier = resolveExplicitWebgpuModuleSpecifier();
  if (explicitSpecifier) {
    const attempt = await tryInstallAndProbeProvider(explicitSpecifier, { force: true });
    return {
      ok: attempt.ok,
      provider: explicitSpecifier,
      detail: attempt.detail,
    };
  }

  if (hasNavigatorGpu() && hasGpuEnums()) {
    const preinstalledProbe = await probeInstalledGpuAdapter();
    if (preinstalledProbe.ok) {
      return { ok: true, provider: 'pre-installed', detail: null };
    }
  }

  let lastFailure = null;
  for (const specifier of DEFAULT_WEBGPU_PROVIDER_SPECIFIERS) {
    const attempt = await tryInstallAndProbeProvider(specifier, { force: true });
    if (attempt.ok) {
      return { ok: true, provider: specifier, detail: null };
    }
    lastFailure = attempt;
  }

  return {
    ok: false,
    provider: lastFailure?.provider ?? null,
    detail: lastFailure?.detail ?? null,
  };
}
