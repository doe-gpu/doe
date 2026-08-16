import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { describe, expect, it } from 'vitest';

import { computeFuzzySimplicialSet } from '@umap-source/fuzzy-set.ts';
import { GPUSgd } from '@umap-source/gpu/sgd.ts';
import { computeEpochsPerSample } from '@umap-source/umap.ts';

type Inputs = {
  fixture: {
    pointsPerCluster: number;
    dimensions: number;
    clusterCenter: number;
    neighbors: number;
    components: number;
    epochs: number;
    initialSeed: number;
    params: {
      a: number;
      b: number;
      gamma: number;
      negativeSampleRate: number;
    };
  };
  sampling: { warmupRuns: number; measuredRuns: number };
  oracle: {
    minimumSpread: number;
    minimumInterToIntraRatio: number;
    requireSameClusterNearestNeighbor: boolean;
    requireExactRepeatIdentity: boolean;
  };
};

const inputPath = process.env.DOE_UMAP_SGD_BENCHMARK_INPUT;
if (!inputPath) throw new Error('DOE_UMAP_SGD_BENCHMARK_INPUT is required.');
const inputs = JSON.parse(await readFile(inputPath, 'utf8')) as Inputs;

function makeClusters(): { vectors: number[][]; labels: number[] } {
  const vectors: number[][] = [];
  const labels: number[] = [];
  const { pointsPerCluster, dimensions, clusterCenter } = inputs.fixture;
  for (let cluster = 0; cluster < 2; cluster += 1) {
    for (let index = 0; index < pointsPerCluster; index += 1) {
      vectors.push(Array.from(
        { length: dimensions },
        (_, dimension) => (
          cluster * clusterCenter
          + Math.sin(index * 1.1 + dimension * 0.7) * 0.4
        ),
      ));
      labels.push(cluster);
    }
  }
  return { vectors, labels };
}

function bruteForceKnn(vectors: number[][], neighbors: number) {
  const indices: number[][] = [];
  const distances: number[][] = [];
  for (let left = 0; left < vectors.length; left += 1) {
    const rows = vectors.map((vector, right) => ({
      right,
      distance: right === left ? Number.POSITIVE_INFINITY : Math.hypot(
        ...vector.map((value, dimension) => value - vectors[left]![dimension]!),
      ),
    })).sort((a, b) => a.distance - b.distance).slice(0, neighbors);
    indices.push(rows.map(({ right }) => right));
    distances.push(rows.map(({ distance }) => distance));
  }
  return { indices, distances };
}

function deterministicRng(seed: number): () => number {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 0x1_0000_0000;
  };
}

function initialEmbedding(labels: number[]): Float32Array {
  const embedding = new Float32Array(labels.length * inputs.fixture.components);
  for (let index = 0; index < labels.length; index += 1) {
    const center = labels[index] === 0 ? -4 : 4;
    embedding[index * 2] = center + Math.sin(index * 0.9) * 0.5;
    embedding[index * 2 + 1] = Math.cos(index * 1.3) * 0.5;
  }
  return embedding;
}

function outputBytes(output: Float32Array): Uint8Array {
  return new Uint8Array(output.buffer, output.byteOffset, output.byteLength);
}

function outputOracle(output: Float32Array, labels: number[]) {
  const pointCount = labels.length;
  const finite = [...output].every(Number.isFinite);
  const meanX = labels.reduce((sum, _, index) => sum + output[index * 2]!, 0)
    / pointCount;
  const spread = Math.sqrt(labels.reduce((sum, _, index) => {
    const delta = output[index * 2]! - meanX;
    return sum + delta * delta;
  }, 0) / pointCount);
  let intraSum = 0;
  let intraCount = 0;
  let interSum = 0;
  let interCount = 0;
  let sameClusterNearestNeighbors = 0;
  for (let left = 0; left < pointCount; left += 1) {
    let nearestDistance = Number.POSITIVE_INFINITY;
    let nearestLabel = -1;
    for (let right = 0; right < pointCount; right += 1) {
      if (left === right) continue;
      const distance = Math.hypot(
        output[left * 2]! - output[right * 2]!,
        output[left * 2 + 1]! - output[right * 2 + 1]!,
      );
      if (right > left) {
        if (labels[left] === labels[right]) {
          intraSum += distance;
          intraCount += 1;
        } else {
          interSum += distance;
          interCount += 1;
        }
      }
      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestLabel = labels[right]!;
      }
    }
    if (nearestLabel === labels[left]) sameClusterNearestNeighbors += 1;
  }
  const meanIntra = intraSum / intraCount;
  const meanInter = interSum / interCount;
  return {
    finite,
    spread,
    meanIntra,
    meanInter,
    interToIntraRatio: meanInter / meanIntra,
    sameClusterNearestNeighbors,
    pointCount,
    pass: finite
      && spread > inputs.oracle.minimumSpread
      && meanInter > meanIntra * inputs.oracle.minimumInterToIntraRatio
      && (
        !inputs.oracle.requireSameClusterNearestNeighbor
        || sameClusterNearestNeighbors === pointCount
      ),
  };
}

async function executeSample(sampleKind: 'warmup' | 'measured', sampleIndex: number) {
  const { vectors, labels } = makeClusters();
  const knn = bruteForceKnn(vectors, inputs.fixture.neighbors);
  const graph = computeFuzzySimplicialSet(
    knn.indices,
    knn.distances,
    inputs.fixture.neighbors,
  );
  const epochsPerSample = computeEpochsPerSample(
    graph.vals,
    inputs.fixture.epochs,
  );
  const started = performance.now();
  const optimizer = new GPUSgd();
  await optimizer.init();
  const output = await optimizer.optimize(
    initialEmbedding(labels),
    new Uint32Array(graph.rows),
    new Uint32Array(graph.cols),
    epochsPerSample,
    labels.length,
    inputs.fixture.components,
    inputs.fixture.epochs,
    inputs.fixture.params,
    undefined,
    deterministicRng(inputs.fixture.initialSeed),
  );
  const durationMs = performance.now() - started;
  const bytes = outputBytes(output);
  return {
    sampleKind,
    sampleIndex,
    durationMs,
    outputSha256: createHash('sha256').update(bytes).digest('hex'),
    outputBase64: Buffer.from(bytes).toString('base64'),
    outputByteLength: bytes.byteLength,
    oracle: outputOracle(output, labels),
    dispatch: {
      edgeCount: graph.rows.length,
      embeddingElementCount: output.length,
      epochs: inputs.fixture.epochs,
      sgdWorkgroupsPerEpoch: Math.ceil(graph.rows.length / 256),
      applyWorkgroupsPerEpoch: Math.ceil(output.length / 256),
      totalDispatches: inputs.fixture.epochs * 2,
    },
  };
}

describe('governed UMAP SGD selected operation', () => {
  it('records exact deterministic output and complete operation timing', async () => {
    const { create, globals } = await import('webgpu');
    Object.assign(globalThis, globals);
    const gpu = create([]);
    if (typeof globalThis.navigator === 'undefined') {
      Object.defineProperty(globalThis, 'navigator', {
        value: { gpu },
        configurable: true,
        writable: true,
      });
    } else {
      (globalThis.navigator as { gpu?: unknown }).gpu = gpu;
    }
    const samples = [];
    for (let index = 0; index < inputs.sampling.warmupRuns; index += 1) {
      samples.push(await executeSample('warmup', index + 1));
    }
    for (let index = 0; index < inputs.sampling.measuredRuns; index += 1) {
      samples.push(await executeSample('measured', index + 1));
    }
    const measured = samples.filter(({ sampleKind }) => sampleKind === 'measured');
    const identities = new Set(measured.map(({ outputSha256 }) => outputSha256));
    expect(measured.every(({ oracle }) => oracle.pass)).toBe(true);
    if (inputs.oracle.requireExactRepeatIdentity) expect(identities.size).toBe(1);
    console.log(`DOE_UMAP_SGD_BENCHMARK=${JSON.stringify({ samples })}`);
  });
});
