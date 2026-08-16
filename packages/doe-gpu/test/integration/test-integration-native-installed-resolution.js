import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, '../..');
const packagesRoot = dirname(packageRoot);
const platformPackageName = new Map([
  ['linux-x64', 'doe-gpu-linux-x64'],
  ['darwin-arm64', 'doe-gpu-darwin-arm64'],
]).get(`${process.platform}-${process.arch}`);

if (!platformPackageName) {
  console.log(`installed native resolution: skipped ${process.platform}-${process.arch}`);
  process.exit(0);
}

const platformPackageRoot = resolve(packagesRoot, platformPackageName);
const platformLibraryName = process.platform === 'darwin'
  ? 'libwebgpu_doe.dylib'
  : 'libwebgpu_doe.so';
if (!existsSync(resolve(platformPackageRoot, 'bin', platformLibraryName))) {
  console.log(`installed native resolution: skipped unstaged ${platformPackageName}`);
  process.exit(0);
}

const scratch = await mkdtemp(join(tmpdir(), 'doe-gpu-installed-resolution-'));
const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm';

function execute(command, args, cwd = scratch) {
  return spawnSync(command, args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
  });
}

function requireSuccess(result, label) {
  if (result.status !== 0) {
    throw new Error(`${label} failed:\n${result.stdout}\n${result.stderr}`);
  }
}

function pack(directory, label) {
  const result = execute(npm, [
    'pack',
    '--ignore-scripts',
    '--pack-destination',
    scratch,
    '--json',
  ], directory);
  requireSuccess(result, `${label} pack`);
  return resolve(scratch, JSON.parse(result.stdout)[0].filename);
}

try {
  const wrapperTarball = pack(packageRoot, 'wrapper');
  const platformTarball = pack(platformPackageRoot, 'platform');
  await writeFile(resolve(scratch, 'package.json'), `${JSON.stringify({
    name: 'doe-gpu-installed-resolution-fixture',
    private: true,
    type: 'module',
  }, null, 2)}\n`);
  const installed = execute(npm, [
    'install',
    '--ignore-scripts',
    '--omit=optional',
    '--package-lock=false',
    '--no-audit',
    '--no-fund',
    wrapperTarball,
    platformTarball,
  ]);
  requireSuccess(installed, 'native clean install');

  const installedWrapperRoot = resolve(scratch, 'node_modules/doe-gpu');
  const installedPlatformRoot = resolve(scratch, `node_modules/${platformPackageName}`);
  const installedModuleUrl = pathToFileURL(resolve(installedWrapperRoot, 'src/index.js')).href;
  const permissionProbe = execute(process.execPath, [
    '--permission',
    '--allow-addons',
    `--allow-fs-read=${installedWrapperRoot}`,
    `--allow-fs-read=${installedPlatformRoot}`,
    '--input-type=module',
    '--eval',
    `const {providerInfo}=await import(${JSON.stringify(installedModuleUrl)});process.stdout.write(JSON.stringify(providerInfo()));`,
  ]);
  requireSuccess(permissionProbe, 'installed native Node permission probe');
  const provider = JSON.parse(permissionProbe.stdout);
  if (provider.loaded !== true
      || provider.doeNative !== true
      || provider.buildMetadataSource !== 'prebuild') {
    throw new Error(`permission probe did not load the platform package: ${permissionProbe.stdout}`);
  }
  if (!provider.doeLibraryPath?.startsWith(`${installedPlatformRoot}/`)) {
    throw new Error(`permission probe escaped the installed platform package: ${permissionProbe.stdout}`);
  }
  console.log(`installed native resolution: ok ${process.platform}-${process.arch}`);
} finally {
  await rm(scratch, { recursive: true, force: true });
}
