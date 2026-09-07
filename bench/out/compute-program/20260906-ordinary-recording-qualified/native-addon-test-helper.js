import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export async function loadNativeAddon() {
  const nativeUrl = import.meta.resolve('doe-gpu/native');
  const packageRoot = fileURLToPath(new URL('../', nativeUrl));
  const require = createRequire(nativeUrl);
  const { isInstalledPackageRoot, resolvePlatformPackageAddonPath } = await import(
    new URL('./vendor/webgpu/platform-package.js', nativeUrl)
  );
  const localAddon = resolve(packageRoot, 'build/Release/doe_napi.node');
  const addonPath = !isInstalledPackageRoot(packageRoot) && existsSync(localAddon)
    ? localAddon : resolvePlatformPackageAddonPath({ requireFn: require,
      workspaceRoot: resolve(packageRoot, '../..') });
  assert(addonPath, 'qualification requires a retained native addon');
  return require(addonPath);
}
