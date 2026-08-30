import { createHash } from 'node:crypto';
import { existsSync } from 'node:fs';
import { copyFile, mkdir, readFile, stat } from 'node:fs/promises';
import { relative, resolve, sep } from 'node:path';

export async function sha256File(path) {
  return createHash('sha256').update(await readFile(path)).digest('hex');
}

export function sha256Json(value) {
  return createHash('sha256').update(JSON.stringify(value)).digest('hex');
}

export function bundleRelativePath(path, bundleRoot) {
  const resolved = resolve(path);
  const bundleRelative = relative(resolve(bundleRoot), resolved);
  if (bundleRelative === '..' || bundleRelative.startsWith(`..${sep}`)) {
    throw new Error(`release-candidate evidence escaped its bundle: ${resolved}`);
  }
  return bundleRelative.split(sep).join('/');
}

export function unexpectedSourceChanges(statusOutput, bundleRoot) {
  return statusOutput
    .split('\n')
    .filter(Boolean)
    .filter((line) => {
      const status = line.slice(0, 2);
      const path = line.slice(3);
      return status !== '??'
        || (path !== bundleRoot && !path.startsWith(`${bundleRoot}/`));
    });
}

export async function retainPackageArtifact({ packed, expectedSha256, bundleRoot }) {
  const artifactDirectory = resolve(bundleRoot, 'packages');
  const retainedPath = resolve(artifactDirectory, packed.manifest.filename);
  await mkdir(artifactDirectory, { recursive: true });
  if (existsSync(retainedPath)) {
    const retainedSha256 = await sha256File(retainedPath);
    const retainedStat = await stat(retainedPath);
    if (retainedSha256 !== expectedSha256 || retainedStat.size !== packed.manifest.size) {
      throw new Error(
        `retained package artifact conflicts with candidate bytes: ${retainedPath}`,
      );
    }
  } else {
    await copyFile(packed.tarball, retainedPath);
  }
  const retainedSha256 = await sha256File(retainedPath);
  const retainedStat = await stat(retainedPath);
  if (retainedSha256 !== expectedSha256 || retainedStat.size !== packed.manifest.size) {
    throw new Error(`retained package artifact failed verification: ${retainedPath}`);
  }
  return bundleRelativePath(retainedPath, bundleRoot);
}
