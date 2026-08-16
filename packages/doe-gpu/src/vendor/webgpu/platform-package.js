import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PLATFORM_PACKAGE_NAMES = Object.freeze({
  'darwin-arm64': 'doe-gpu-darwin-arm64',
  'darwin-x64': 'doe-gpu-darwin-x64',
  'linux-arm64': 'doe-gpu-linux-arm64',
  'linux-x64': 'doe-gpu-linux-x64',
  'win32-x64': 'doe-gpu-win32-x64',
});

const __dirname = dirname(fileURLToPath(import.meta.url));
const PACKAGE_ROOT = resolve(__dirname, '..', '..', '..');
const WORKSPACE_ROOT = resolve(PACKAGE_ROOT, '..', '..');
const require = createRequire(import.meta.url);

function platformTag(platform = process.platform, arch = process.arch) {
  return `${platform}-${arch}`;
}

function currentPlatformPackageName(platform = process.platform, arch = process.arch) {
  return PLATFORM_PACKAGE_NAMES[platformTag(platform, arch)] ?? null;
}

function isInstalledPackageRoot(packageRoot = PACKAGE_ROOT) {
  return resolve(packageRoot).split(/[\\/]+/u).includes('node_modules');
}

function resolveInstalledPlatformPackageRoot({
  platform = process.platform,
  arch = process.arch,
  requireFn = require,
  workspaceRoot = WORKSPACE_ROOT,
} = {}) {
  const packageName = currentPlatformPackageName(platform, arch);
  if (!packageName) {
    return null;
  }

  try {
    const packageJsonPath = requireFn.resolve(`${packageName}/package.json`);
    return dirname(packageJsonPath);
  } catch {
    const workspacePackageRoot = resolve(workspaceRoot, 'packages', packageName);
    if (existsSync(resolve(workspacePackageRoot, 'package.json'))) {
      return workspacePackageRoot;
    }
    return null;
  }
}

function libraryBasenamesForPlatform(platform = process.platform) {
  if (platform === 'win32') {
    return ['webgpu_doe.dll', 'libwebgpu_doe.dll'];
  }
  if (platform === 'darwin') {
    return ['libwebgpu_doe.dylib'];
  }
  return ['libwebgpu_doe.so'];
}

function resolvePlatformPackageAddonPath(options = {}) {
  const packageRoot = resolveInstalledPlatformPackageRoot(options);
  if (!packageRoot) {
    return null;
  }
  const addonPath = resolve(packageRoot, 'bin', 'doe_napi.node');
  return existsSync(addonPath) ? addonPath : null;
}

function resolvePlatformPackageLibraryPath(options = {}) {
  const packageRoot = resolveInstalledPlatformPackageRoot(options);
  if (!packageRoot) {
    return null;
  }
  for (const basename of libraryBasenamesForPlatform(options.platform ?? process.platform)) {
    const candidate = resolve(packageRoot, 'bin', basename);
    if (existsSync(candidate)) {
      return candidate;
    }
  }
  return null;
}

export {
  PACKAGE_ROOT,
  WORKSPACE_ROOT,
  libraryBasenamesForPlatform,
  isInstalledPackageRoot,
  resolveInstalledPlatformPackageRoot,
  resolvePlatformPackageAddonPath,
  resolvePlatformPackageLibraryPath,
};
