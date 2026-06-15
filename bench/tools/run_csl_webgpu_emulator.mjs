#!/usr/bin/env node

import { createHash } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, '..', '..');
const DOE_NODE_WEBGPU_PATH = resolve(REPO_ROOT, 'packages/doe-gpu/src/node-webgpu.js');
const BYTES_PER_WORD = 4;
const WEBGPU_WORKGROUP_SIZE = 64;
const QK_K = 256;
const Q4K_BLOCK_BYTES = 144;
const F32_NEG_MAX = -3.4028235e38;
const RESULT_PLACEHOLDER_HASH =
  'sha256:0000000000000000000000000000000000000000000000000000000000000000';

function parseArgs(argv) {
  const args = {
    input: null,
    out: null,
    backend: 'auto',
    d2hOutDir: null,
    kernelTrace: null,
  };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = argv[i + 1];
    if (arg === '--input') {
      args.input = next;
      i += 1;
    } else if (arg === '--out') {
      args.out = next;
      i += 1;
    } else if (arg === '--backend') {
      args.backend = next;
      i += 1;
    } else if (arg === '--d2h-out-dir') {
      args.d2hOutDir = next;
      i += 1;
    } else if (arg === '--kernel-trace') {
      args.kernelTrace = next;
      i += 1;
    } else {
      throw new Error(`unrecognized argument: ${arg}`);
    }
  }
  if (!args.input) throw new Error('--input is required');
  if (!args.out) throw new Error('--out is required');
  if (!['auto', 'cpu', 'webgpu'].includes(args.backend)) {
    throw new Error('--backend must be one of: auto, cpu, webgpu');
  }
  return args;
}

function readJson(path) {
  return JSON.parse(readFileSync(path, 'utf-8'));
}

function repoPath(path) {
  return resolve(REPO_ROOT, path);
}

function repoRelative(path) {
  const absolute = resolve(path);
  if (absolute.startsWith(`${REPO_ROOT}/`)) {
    return absolute.slice(REPO_ROOT.length + 1);
  }
  return absolute;
}

function sha256Bytes(bytes) {
  return `sha256:${createHash('sha256').update(bytes).digest('hex')}`;
}

function sha256File(path) {
  return sha256Bytes(readFileSync(path));
}

function stableStringify(value) {
  if (Array.isArray(value)) {
    return `[${value.map((item) => stableStringify(item)).join(',')}]`;
  }
  if (value && typeof value === 'object') {
    const entries = Object.keys(value).sort().map((key) => (
      `${JSON.stringify(key)}:${stableStringify(value[key])}`
    ));
    return `{${entries.join(',')}}`;
  }
  return JSON.stringify(value);
}

function resultHash(payload) {
  const clone = JSON.parse(JSON.stringify(payload));
  clone.resultSha256 = RESULT_PLACEHOLDER_HASH;
  return sha256Bytes(Buffer.from(stableStringify(clone), 'utf-8'));
}

function bytesPerElement(dataType) {
  if (dataType === 'MEMCPY_32BIT') return 4;
  if (dataType === 'MEMCPY_16BIT') return 2;
  throw new Error(`unsupported memcpy dataType: ${dataType}`);
}

function operationByteLength(operation) {
  return (
    operation.roi.width *
    operation.roi.height *
    operation.elementsPerPE *
    bytesPerElement(operation.dataType)
  );
}

function blocker(code, message, fields = {}) {
  return { code, message, ...fields };
}

function safeFileName(value) {
  return value.replace(/[^A-Za-z0-9_.-]+/g, '_');
}

function writeD2hOutputFile(d2hOutDir, operation, symbolName, bytes) {
  if (!d2hOutDir) return null;
  const outDir = resolve(d2hOutDir);
  mkdirSync(outDir, { recursive: true });
  const path = resolve(
    outDir,
    `${safeFileName(operation.operationId)}-${safeFileName(symbolName)}.bin`,
  );
  writeFileSync(path, bytes);
  return {
    path: repoRelative(path),
    byteLength: bytes.byteLength,
    sha256: sha256Bytes(bytes),
  };
}

function fixtureMap(input) {
  const fixtures = input.hostInputs?.fixtureFiles ?? [];
  const bySymbol = new Map();
  const byOperation = new Map();
  for (const fixture of fixtures) {
    const path = repoPath(fixture.path);
    if (!existsSync(path)) {
      throw new Error(`fixture file is missing: ${fixture.path}`);
    }
    const actualHash = sha256File(path);
    if (actualHash !== fixture.sha256) {
      throw new Error(
        `fixture hash mismatch for ${fixture.path}: expected ${fixture.sha256}, got ${actualHash}`,
      );
    }
    const entry = {
      ...fixture,
      path,
      bytes: readFileSync(path),
    };
    if (fixture.byteLength != null && fixture.byteLength !== entry.bytes.byteLength) {
      throw new Error(
        `fixture byteLength mismatch for ${fixture.path}: expected ${fixture.byteLength}, got ${entry.bytes.byteLength}`,
      );
    }
    bySymbol.set(fixture.deviceSymbol, entry);
    if (fixture.operationId) byOperation.set(fixture.operationId, entry);
  }
  return { bySymbol, byOperation };
}

function symbolNameForMemcpy(operation) {
  if (operation.targetKind === 'device_symbol') return operation.deviceSymbol;
  if (operation.targetKind === 'memcpy_color') {
    return `memcpy_color:${operation.memcpyColor}`;
  }
  throw new Error(`unsupported memcpy targetKind: ${operation.targetKind}`);
}

function buildSymbolTable(input) {
  const symbols = new Map();
  for (const symbol of input.operationGraph.exportedSymbols) {
    if (symbol.kind === 'device_variable') {
      const preallocBytes = Number.isInteger(symbol.byteLength) && symbol.byteLength > 0 ? symbol.byteLength : 0;
      symbols.set(symbol.name, {
        name: symbol.name,
        bytes: new Uint8Array(preallocBytes),
      });
    }
  }
  for (const operation of input.operationGraph.operations) {
    if (operation.kind !== 'memcpy_h2d' && operation.kind !== 'memcpy_d2h') {
      continue;
    }
    const name = symbolNameForMemcpy(operation);
    const byteLength = operationByteLength(operation);
    const current = symbols.get(name);
    if (!current || current.bytes.byteLength < byteLength) {
      symbols.set(name, {
        name,
        bytes: new Uint8Array(byteLength),
      });
    }
  }
  return symbols;
}

function compileTargetPatterns(operationGraph) {
  const byName = new Map();
  for (const pattern of operationGraph.kernelPatterns ?? []) {
    byName.set(pattern.targetName, pattern.pattern);
  }
  return byName;
}

function inferSemantic(pattern, source) {
  if (pattern === 'gather' || source.includes('embedding gather')) {
    return 'gather';
  }
  if (
    pattern === 'rms_norm' ||
    (pattern === 'reduction' && source.includes('inv_rms')) ||
    source.includes('mean_sq') && source.includes('inv_rms')
  ) {
    return 'rms_norm';
  }
  if (
    pattern === 'gelu' ||
    source.includes('0.044715') && source.includes('math.tanh')
  ) {
    return 'gelu';
  }
  if (
    pattern === 'residual' ||
    pattern === 'residual_add' ||
    source.includes(' + residual[')
  ) {
    return 'residual_add';
  }
  if (
    pattern === 'element_wise' &&
    source.includes('var input:') &&
    source.includes('var output:') &&
    source.includes('* 1.0') &&
    !source.includes('residual[')
  ) {
    return 'elementwise_identity';
  }
  if (
    pattern === 'tiled_matmul' ||
    source.includes('SUMMA tiled matmul') ||
    source.includes('Local GEMM step')
  ) {
    return 'tiled_matmul';
  }
  if (
    pattern === 'rope' ||
    source.includes('rotary position embeddings') ||
    source.includes('cos_table') && source.includes('sin_table')
  ) {
    return 'rope';
  }
  if (
    pattern === 'attention_tiled' ||
    source.includes('tiled Flash Attention') ||
    source.includes('fn finalize() void') && source.includes('m_state') && source.includes('l_state')
  ) {
    return 'attention_tiled';
  }
  if (
    pattern === 'attention_decode' ||
    source.includes('decode attention') ||
    source.includes('decode_sliding_window')
  ) {
    return 'attention_decode';
  }
  if (
    pattern === 'fused_gemv_dequant' ||
    source.includes('fused GEMV + Q4K dequant') ||
    source.includes('Q4K_BLOCK_BYTES')
  ) {
    return 'fused_gemv_dequant';
  }
  if (
    pattern === 'kv_write' ||
    (source.includes('key_cache') &&
     source.includes('val_cache') &&
     source.includes('key_proj') &&
     source.includes('val_proj'))
  ) {
    return 'kv_write';
  }
  if (
    pattern === 'sample' ||
    source.includes('token sampling') ||
    source.includes('output_token')
  ) {
    return 'sample';
  }
  const bodyMatch = /fn\s+compute\s*\([^)]*\)\s+void\s*\{([\s\S]*?)\n\}/m.exec(source);
  const body = bodyMatch ? bodyMatch[1] : '';
  if (body.includes('sys_mod.unblock_cmd_stream()') && !body.includes(' = ')) {
    return 'noop_unblock';
  }
  return 'unsupported';
}

function inspectSources(input) {
  const patternByName = compileTargetPatterns(input.operationGraph);
  const compileTargets = [];
  for (const target of input.compileTargets) {
    const peProgramPath = repoPath(target.peProgram.path);
    const source = existsSync(peProgramPath) ? readFileSync(peProgramPath, 'utf-8') : '';
    const pattern = patternByName.get(target.name);
    compileTargets.push({
      name: target.name,
      pattern,
      layoutSha256: target.layout.sha256,
      peProgramSha256: target.peProgram.sha256,
      semantic: inferSemantic(pattern, source),
      compileParams: target.compileParams ?? {},
    });
  }
  return {
    compileTargetCount: input.compileTargets.length,
    exportedSymbolCount: input.operationGraph.exportedSymbols.length,
    operationCount: input.operationGraph.operations.length,
    compileTargets,
  };
}

function targetForLaunch(input, inspection, operation) {
  if (operation && operation.target) {
    const found = inspection.compileTargets.find((t) => t.name === operation.target);
    if (found) return found;
  }
  const graphTargets = input.operationGraph.compile?.compileTargets ?? [];
  const targetName = graphTargets[0]?.name ?? input.compileTargets[0]?.name;
  return inspection.compileTargets.find((target) => target.name === targetName)
    ?? inspection.compileTargets[0];
}

function bindSymbols(symbols, bindings) {
  if (!bindings) return symbols;
  const resolve = (name) => bindings[name] || name;
  return {
    get: (name) => symbols.get(resolve(name)),
    set: (name, value) => symbols.set(resolve(name), value),
    has: (name) => symbols.has(resolve(name)),
  };
}

function float32View(symbol, name) {
  if (!symbol) throw new Error(`missing symbol: ${name}`);
  if (symbol.bytes.byteLength % BYTES_PER_WORD !== 0) {
    throw new Error(`symbol ${name} byteLength is not f32-aligned`);
  }
  return new Float32Array(
    symbol.bytes.buffer,
    symbol.bytes.byteOffset,
    symbol.bytes.byteLength / BYTES_PER_WORD,
  );
}

function u32View(symbol, name) {
  if (!symbol) throw new Error(`missing symbol: ${name}`);
  if (symbol.bytes.byteLength % BYTES_PER_WORD !== 0) {
    throw new Error(`symbol ${name} byteLength is not u32-aligned`);
  }
  return new Uint32Array(
    symbol.bytes.buffer,
    symbol.bytes.byteOffset,
    symbol.bytes.byteLength / BYTES_PER_WORD,
  );
}

function numericParam(target, name, fallback = null) {
  const value = target?.compileParams?.[name];
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (fallback != null) return fallback;
  throw new Error(`compile target ${target?.name ?? '<unknown>'} missing numeric ${name}`);
}

function integerParam(target, name, fallback = null) {
  const value = numericParam(target, name, fallback);
  if (!Number.isInteger(value)) {
    throw new Error(`compile target ${target?.name ?? '<unknown>'} ${name} is not an integer`);
  }
  return value;
}

function boolParam(target, name, fallback) {
  const value = target?.compileParams?.[name];
  if (typeof value === 'boolean') return value;
  return fallback;
}

function integerParamAlias(target, preferred, fallbackName) {
  const value = target?.compileParams?.[preferred];
  if (typeof value === 'number' && Number.isFinite(value)) {
    if (!Number.isInteger(value)) {
      throw new Error(`compile target ${target?.name ?? '<unknown>'} ${preferred} is not an integer`);
    }
    return value;
  }
  return integerParam(target, fallbackName);
}

function u8View(symbol, name) {
  if (!symbol) throw new Error(`missing symbol: ${name}`);
  return new Uint8Array(
    symbol.bytes.buffer,
    symbol.bytes.byteOffset,
    symbol.bytes.byteLength,
  );
}

function assertElementCount(name, actual, expected) {
  if (actual < expected) {
    throw new Error(`${name} has ${actual} elements, expected at least ${expected}`);
  }
}

function peIndex(width, x, y) {
  return y * width + x;
}

function inferPeCountFromSymbol(symbol, elementsPerPe, name) {
  if (!Number.isInteger(elementsPerPe) || elementsPerPe <= 0) {
    throw new Error(`invalid elementsPerPE for ${name}: ${elementsPerPe}`);
  }
  if (!symbol || symbol.bytes.byteLength === 0) return 0;
  const elements = symbol.bytes.byteLength / BYTES_PER_WORD;
  if (!Number.isInteger(elements) || elements % elementsPerPe !== 0) {
    throw new Error(`${name} byteLength does not divide into PE-local chunks`);
  }
  return elements / elementsPerPe;
}

function f32State(state, key, elements) {
  if (!Number.isInteger(elements) || elements < 0) {
    throw new Error(`invalid state element count for ${key}: ${elements}`);
  }
  const byteLength = elements * BYTES_PER_WORD;
  let entry = state.get(key);
  if (!entry) {
    entry = { name: key, bytes: new Uint8Array(byteLength) };
    state.set(key, entry);
  }
  if (entry.bytes.byteLength !== byteLength) {
    throw new Error(
      `state ${key} has ${entry.bytes.byteLength} bytes, expected ${byteLength}`,
    );
  }
  return float32View(entry, key);
}

function targetStateKey(target, name) {
  return `${target.name}:${name}`;
}

function float16ToFloat32(bits) {
  const sign = (bits & 0x8000) ? -1 : 1;
  const exponent = (bits >> 10) & 0x1f;
  const fraction = bits & 0x03ff;
  if (exponent === 0) {
    return sign * Math.pow(2, -14) * (fraction / 1024);
  }
  if (exponent === 31) {
    return fraction === 0 ? sign * Infinity : NaN;
  }
  return sign * Math.pow(2, exponent - 15) * (1 + fraction / 1024);
}

function q4kScale(weight, offset) {
  return float16ToFloat32(weight[offset] | (weight[offset + 1] << 8));
}

function executeResidualAddCpu(symbols) {
  const input = float32View(symbols.get('input'), 'input');
  const residual = float32View(symbols.get('residual'), 'residual');
  const output = float32View(symbols.get('output'), 'output');
  for (let i = 0; i < output.length; i += 1) {
    output[i] = input[i] + residual[i];
  }
}

function executeElementwiseIdentityCpu(symbols) {
  const input = float32View(symbols.get('input'), 'input');
  const output = float32View(symbols.get('output'), 'output');
  for (let i = 0; i < output.length; i += 1) {
    output[i] = input[i];
  }
}

function executeGeluCpu(symbols) {
  const input = float32View(symbols.get('input'), 'input');
  const output = float32View(symbols.get('output'), 'output');
  for (let i = 0; i < output.length; i += 1) {
    const x = input[i];
    const t = 0.7978845608 * (x + 0.044715 * x * x * x);
    output[i] = 0.5 * x * (1.0 + Math.tanh(t));
  }
}

function executeRmsNormCpu(symbols, target) {
  const input = float32View(symbols.get('input'), 'input');
  const weight = float32View(symbols.get('weight'), 'weight');
  const output = float32View(symbols.get('output'), 'output');
  const hiddenSize = target ? integerParam(target, 'hidden_size', weight.length) : weight.length;
  const rowLen = hiddenSize > 0 ? hiddenSize : weight.length;
  for (let row = 0; row < output.length; row += rowLen) {
    let sumSq = 0.0;
    for (let i = 0; i < rowLen; i += 1) {
      const v = input[row + i];
      sumSq += v * v;
    }
    const invRms = 1.0 / Math.sqrt(sumSq / rowLen + 0.000001);
    for (let i = 0; i < rowLen; i += 1) {
      output[row + i] = input[row + i] * invRms * (1.0 + weight[i]);
    }
  }
}

function executeGatherCpu(symbols, target) {
  const indices = u32View(symbols.get('indices'), 'indices');
  const table = float32View(symbols.get('table'), 'table');
  const output = float32View(symbols.get('output'), 'output');
  const tokensPerChunk = numericParam(target, 'tokens_per_chunk');
  const hiddenPerPe = numericParam(target, 'hidden_per_pe');
  const rowsPerPe = numericParam(target, 'rows_per_pe');
  const elemsPerPe = tokensPerChunk * hiddenPerPe;
  const tableElemsPerPe = rowsPerPe * hiddenPerPe;
  for (let idx = 0; idx < output.length; idx += 1) {
    const hidden = idx % hiddenPerPe;
    const token = Math.floor(idx / hiddenPerPe) % tokensPerChunk;
    const pe = Math.floor(idx / elemsPerPe);
    const tokenId = indices[pe * tokensPerChunk + token];
    const rowStart = pe * rowsPerPe;
    if (tokenId >= rowStart && tokenId < rowStart + rowsPerPe) {
      const localRow = tokenId - rowStart;
      const tableIndex = pe * tableElemsPerPe + localRow * hiddenPerPe + hidden;
      output[idx] = table[tableIndex];
    } else {
      output[idx] = 0.0;
    }
  }
}

function executeTiledMatmulCpu(symbols, target) {
  const a = float32View(symbols.get('a'), 'a');
  const b = float32View(symbols.get('b'), 'b');
  const c = float32View(symbols.get('c'), 'c');
  const p = integerParam(target, 'P');
  const mt = integerParam(target, 'Mt');
  const kt = integerParam(target, 'Kt');
  const nt = integerParam(target, 'Nt');
  const aTile = mt * kt;
  const bTile = kt * nt;
  const cTile = mt * nt;
  const peCount = p * p;
  assertElementCount('a', a.length, peCount * aTile);
  assertElementCount('b', b.length, peCount * bTile);
  assertElementCount('c', c.length, peCount * cTile);
  for (let py = 0; py < p; py += 1) {
    for (let px = 0; px < p; px += 1) {
      const dstPe = peIndex(p, px, py);
      const cBase = dstPe * cTile;
      for (let i = 0; i < mt; i += 1) {
        for (let j = 0; j < nt; j += 1) {
          let acc = c[cBase + i * nt + j];
          for (let step = 0; step < p; step += 1) {
            const aBase = peIndex(p, step, py) * aTile;
            const bBase = peIndex(p, px, step) * bTile;
            for (let k = 0; k < kt; k += 1) {
              acc += a[aBase + i * kt + k] * b[bBase + j * kt + k];
            }
          }
          c[cBase + i * nt + j] = acc;
        }
      }
    }
  }
}

function executeRopeCpu(symbols, target) {
  const input = float32View(symbols.get('input'), 'input');
  const cosTable = float32View(symbols.get('cos_table'), 'cos_table');
  const sinTable = float32View(symbols.get('sin_table'), 'sin_table');
  const headDim = integerParam(target, 'head_dim', input.length);
  const numPairs = integerParam(target, 'num_pairs', Math.floor(headDim / 2));
  const interleaved = boolParam(target, 'interleaved', true);
  const peCount = inferPeCountFromSymbol(symbols.get('input'), headDim, 'input');
  assertElementCount('cos_table', cosTable.length, numPairs);
  assertElementCount('sin_table', sinTable.length, numPairs);
  for (let pe = 0; pe < peCount; pe += 1) {
    const base = pe * headDim;
    const tableBase = cosTable.length >= peCount * numPairs ? pe * numPairs : 0;
    for (let pair = 0; pair < numPairs; pair += 1) {
      const cosVal = cosTable[tableBase + pair];
      const sinVal = sinTable[tableBase + pair];
      const dim0 = interleaved ? pair * 2 : pair;
      const dim1 = interleaved ? dim0 + 1 : dim0 + numPairs;
      const x0 = input[base + dim0];
      const x1 = input[base + dim1];
      input[base + dim0] = x0 * cosVal - x1 * sinVal;
      input[base + dim1] = x0 * sinVal + x1 * cosVal;
    }
  }
}

function executeKvWriteCpu(symbols, target) {
  const keyProj = float32View(symbols.get('key_proj'), 'key_proj');
  const valProj = float32View(symbols.get('val_proj'), 'val_proj');
  const keyCache = float32View(symbols.get('key_cache'), 'key_cache');
  const valCache = float32View(symbols.get('val_cache'), 'val_cache');
  const position = u32View(symbols.get('position'), 'position');
  const headDim = integerParam(target, 'head_dim', keyProj.length);
  const peCount = inferPeCountFromSymbol(symbols.get('key_proj'), headDim, 'key_proj');
  const maxSeqLen = integerParam(
    target,
    'max_seq_len',
    keyCache.length / Math.max(1, peCount * headDim),
  );
  assertElementCount('val_proj', valProj.length, peCount * headDim);
  assertElementCount('key_cache', keyCache.length, peCount * maxSeqLen * headDim);
  assertElementCount('val_cache', valCache.length, peCount * maxSeqLen * headDim);
  assertElementCount('position', position.length, position.length >= peCount ? peCount : 1);
  for (let pe = 0; pe < peCount; pe += 1) {
    const pos = position.length >= peCount ? position[pe] : position[0];
    if (pos >= maxSeqLen) {
      throw new Error(`position ${pos} exceeds max_seq_len ${maxSeqLen}`);
    }
    const srcBase = pe * headDim;
    const dstBase = (pe * maxSeqLen + pos) * headDim;
    for (let d = 0; d < headDim; d += 1) {
      keyCache[dstBase + d] = keyProj[srcBase + d];
      valCache[dstBase + d] = valProj[srcBase + d];
    }
  }
}

function executeAttentionTiledCpu(symbols, target, operation, state) {
  const query = float32View(symbols.get('query'), 'query');
  const key = float32View(symbols.get('key'), 'key');
  const val = float32View(symbols.get('val'), 'val');
  const output = float32View(symbols.get('output'), 'output');
  const headDim = integerParam(target, 'head_dim');
  const blockSize = integerParam(target, 'block_size');
  const qLenPerPe = integerParamAlias(target, 'q_len_per_pe', 'q_len');
  const scale = numericParam(target, 'scale', 0.125);
  const queryPerPe = qLenPerPe * headDim;
  const kvPerPe = blockSize * headDim;
  const peCount = inferPeCountFromSymbol(symbols.get('query'), queryPerPe, 'query');
  assertElementCount('key', key.length, peCount * kvPerPe);
  assertElementCount('val', val.length, peCount * kvPerPe);
  assertElementCount('output', output.length, peCount * queryPerPe);
  const stateElements = peCount * qLenPerPe;
  const mState = f32State(state, targetStateKey(target, 'm_state'), stateElements);
  const lState = f32State(state, targetStateKey(target, 'l_state'), stateElements);

  if (operation.functionName === 'finalize') {
    for (let pe = 0; pe < peCount; pe += 1) {
      for (let qi = 0; qi < qLenPerPe; qi += 1) {
        const stateIdx = pe * qLenPerPe + qi;
        const inv = 1.0 / lState[stateIdx];
        const outBase = pe * queryPerPe + qi * headDim;
        for (let d = 0; d < headDim; d += 1) {
          output[outBase + d] *= inv;
        }
      }
    }
    return;
  }
  if (operation.functionName !== 'compute') {
    throw new Error(`unsupported attention_tiled function: ${operation.functionName}`);
  }

  for (let pe = 0; pe < peCount; pe += 1) {
    for (let qi = 0; qi < qLenPerPe; qi += 1) {
      const stateIdx = pe * qLenPerPe + qi;
      const queryBase = pe * queryPerPe + qi * headDim;
      const kvBase = pe * kvPerPe;
      const outBase = pe * queryPerPe + qi * headDim;
      let mI = mState[stateIdx];
      let lI = lState[stateIdx];
      let blockMax = F32_NEG_MAX;
      for (let bi = 0; bi < blockSize; bi += 1) {
        let score = 0.0;
        for (let d = 0; d < headDim; d += 1) {
          score += query[queryBase + d] * key[kvBase + bi * headDim + d];
        }
        score *= scale;
        if (score > blockMax) blockMax = score;
      }
      const mNew = Math.max(mI, blockMax);
      const rescale = Math.exp(mI - mNew);
      lI *= rescale;
      for (let d = 0; d < headDim; d += 1) {
        output[outBase + d] *= rescale;
      }
      for (let bi = 0; bi < blockSize; bi += 1) {
        let score = 0.0;
        for (let d = 0; d < headDim; d += 1) {
          score += query[queryBase + d] * key[kvBase + bi * headDim + d];
        }
        const weight = Math.exp(score * scale - mNew);
        lI += weight;
        for (let d = 0; d < headDim; d += 1) {
          output[outBase + d] += weight * val[kvBase + bi * headDim + d];
        }
      }
      mState[stateIdx] = mNew;
      lState[stateIdx] = lI;
    }
  }
}

function executeAttentionDecodeCpu(symbols, target) {
  const query = float32View(symbols.get('query'), 'query');
  const key = float32View(symbols.get('key'), 'key');
  const val = float32View(symbols.get('val'), 'val');
  const output = float32View(symbols.get('output'), 'output');
  const position = u32View(symbols.get('position'), 'position');
  const slidingWindow = u32View(symbols.get('sliding_window'), 'sliding_window');
  const headDim = integerParam(target, 'head_dim');
  const kvChunk = integerParam(target, 'kv_chunk');
  const scale = numericParam(target, 'scale', 0.125);
  const peCount = inferPeCountFromSymbol(symbols.get('query'), headDim, 'query');
  assertElementCount('key', key.length, peCount * kvChunk * headDim);
  assertElementCount('val', val.length, peCount * kvChunk * headDim);
  assertElementCount('output', output.length, peCount * headDim);
  assertElementCount('position', position.length, position.length >= peCount ? peCount : 1);
  assertElementCount(
    'sliding_window',
    slidingWindow.length,
    slidingWindow.length >= peCount ? peCount : 1,
  );
  for (let qPe = 0; qPe < peCount; qPe += 1) {
    const queryBase = qPe * headDim;
    const currentPos = position.length >= peCount ? position[qPe] : position[0];
    const window = slidingWindow.length >= peCount ? slidingWindow[qPe] : slidingWindow[0];
    let globalMax = F32_NEG_MAX;
    for (let pe = 0; pe < peCount; pe += 1) {
      for (let kv = 0; kv < kvChunk; kv += 1) {
        const absKey = pe * kvChunk + kv;
        if (window > 0 && currentPos >= window && absKey < currentPos - window + 1) {
          continue;
        }
        let score = 0.0;
        const kvBase = (pe * kvChunk + kv) * headDim;
        for (let d = 0; d < headDim; d += 1) {
          score += query[queryBase + d] * key[kvBase + d];
        }
        score *= scale;
        if (score > globalMax) globalMax = score;
      }
    }
    let globalSum = 0.0;
    for (let pe = 0; pe < peCount; pe += 1) {
      for (let kv = 0; kv < kvChunk; kv += 1) {
        const absKey = pe * kvChunk + kv;
        if (window > 0 && currentPos >= window && absKey < currentPos - window + 1) {
          continue;
        }
        let score = 0.0;
        const kvBase = (pe * kvChunk + kv) * headDim;
        for (let d = 0; d < headDim; d += 1) {
          score += query[queryBase + d] * key[kvBase + d];
        }
        globalSum += Math.exp(score * scale - globalMax);
      }
    }
    const outBase = qPe * headDim;
    for (let d = 0; d < headDim; d += 1) output[outBase + d] = 0.0;
    for (let kv = 0; kv < kvChunk; kv += 1) {
      const absKey = qPe * kvChunk + kv;
      if (window > 0 && currentPos >= window && absKey < currentPos - window + 1) {
        continue;
      }
      let score = 0.0;
      const kvBase = (qPe * kvChunk + kv) * headDim;
      for (let d = 0; d < headDim; d += 1) {
        score += query[queryBase + d] * key[kvBase + d];
      }
      const weight = Math.exp(score * scale - globalMax) / globalSum;
      for (let d = 0; d < headDim; d += 1) {
        output[outBase + d] += weight * val[kvBase + d];
      }
    }
  }
}

function executeFusedGemvDequantCpu(symbols, target) {
  const activation = float32View(symbols.get('activation'), 'activation');
  const weight = u8View(symbols.get('weight'), 'weight');
  const output = float32View(symbols.get('output'), 'output');
  const width = integerParam(target, 'width');
  const height = integerParam(target, 'height', 1);
  const outDimPerPe = integerParam(target, 'out_dim_per_pe');
  const inDimPerPe = integerParam(target, 'in_dim_per_pe');
  const numBlocksPerRow = integerParam(target, 'num_blocks_per_row');
  const peCount = width * height;
  const weightBytesPerPe = outDimPerPe * numBlocksPerRow * Q4K_BLOCK_BYTES;
  assertElementCount('activation', activation.length, peCount * inDimPerPe);
  if (weight.length < peCount * weightBytesPerPe) {
    throw new Error(`weight has ${weight.length} bytes, expected at least ${peCount * weightBytesPerPe}`);
  }
  assertElementCount('output', output.length, peCount * outDimPerPe);
  for (let y = 0; y < height; y += 1) {
    const prefix = Array(outDimPerPe).fill(0.0);
    for (let x = 0; x < width; x += 1) {
      const pe = peIndex(width, x, y);
      const actBase = pe * inDimPerPe;
      const weightBase = pe * weightBytesPerPe;
      const outBase = pe * outDimPerPe;
      for (let row = 0; row < outDimPerPe; row += 1) {
        let partial = 0.0;
        const rowBase = weightBase + row * numBlocksPerRow * Q4K_BLOCK_BYTES;
        for (let block = 0; block < numBlocksPerRow; block += 1) {
          const blockBase = rowBase + block * Q4K_BLOCK_BYTES;
          const scale = q4kScale(weight, blockBase);
          const dataOff = blockBase + 16;
          const actOff = actBase + block * QK_K;
          for (let i = 0; i < 128; i += 1) {
            const byte = weight[dataOff + i];
            partial += ((byte & 0x0f) * scale) * activation[actOff + i * 2];
            partial += ((byte >> 4) * scale) * activation[actOff + i * 2 + 1];
          }
        }
        prefix[row] += partial;
        output[outBase + row] = prefix[row];
      }
    }
  }
}

function executeSampleCpu(symbols, target) {
  const logits = float32View(symbols.get('logits'), 'logits');
  const tokens = u32View(symbols.get('tokens'), 'tokens');
  const width = integerParam(target, 'width', tokens.length);
  const chunkSize = integerParam(target, 'chunk_size', logits.length / Math.max(1, width));
  const temperature = numericParam(target, 'temperature', 1.0);
  const softcap = numericParam(target, 'softcap', 0.0);
  const lastRowOnly = boolParam(target, 'last_row_only', false);
  const totalRows = integerParam(target, 'total_rows', width);
  if (lastRowOnly) {
    assertElementCount('logits', logits.length, totalRows * chunkSize);
    assertElementCount('tokens', tokens.length, 1);
    let bestVal = F32_NEG_MAX;
    let bestIdx = 0;
    const base = (totalRows - 1) * chunkSize;
    for (let i = 0; i < chunkSize; i += 1) {
      let value = logits[base + i];
      if (softcap !== 0.0) value = softcap * Math.tanh(value / softcap);
      value /= temperature;
      if (value > bestVal) { bestVal = value; bestIdx = i; }
    }
    tokens[0] = base + bestIdx;
    return;
  }
  assertElementCount('logits', logits.length, width * chunkSize);
  assertElementCount('tokens', tokens.length, width);
  let bestVal = F32_NEG_MAX;
  let bestIdx = 0;
  for (let pe = 0; pe < width; pe += 1) {
    tokens[pe] = 0;
    const base = pe * chunkSize;
    for (let i = 0; i < chunkSize; i += 1) {
      let value = logits[base + i];
      if (softcap !== 0.0) value = softcap * Math.tanh(value / softcap);
      value /= temperature;
      if (value > bestVal) { bestVal = value; bestIdx = base + i; }
    }
  }
  tokens[Math.max(0, width - 1)] = bestIdx;
}

function executeLaunchCpu(symbols, target, operation, state) {
  if (target.semantic === 'noop_unblock') return;
  if (target.semantic === 'residual_add') return executeResidualAddCpu(symbols);
  if (target.semantic === 'elementwise_identity') {
    return executeElementwiseIdentityCpu(symbols);
  }
  if (target.semantic === 'gelu') return executeGeluCpu(symbols);
  if (target.semantic === 'rms_norm') return executeRmsNormCpu(symbols, target);
  if (target.semantic === 'gather') return executeGatherCpu(symbols, target);
  if (target.semantic === 'tiled_matmul') return executeTiledMatmulCpu(symbols, target);
  if (target.semantic === 'rope') return executeRopeCpu(symbols, target);
  if (target.semantic === 'attention_tiled') {
    return executeAttentionTiledCpu(symbols, target, operation, state);
  }
  if (target.semantic === 'attention_decode') {
    return executeAttentionDecodeCpu(symbols, target);
  }
  if (target.semantic === 'fused_gemv_dequant') {
    return executeFusedGemvDequantCpu(symbols, target);
  }
  if (target.semantic === 'kv_write') return executeKvWriteCpu(symbols, target);
  if (target.semantic === 'sample') return executeSampleCpu(symbols, target);
  throw new Error(`unsupported CSL launch semantic: ${target.semantic}`);
}

async function bootstrapWebGpu() {
  let mod;
  try {
    mod = await import(pathToFileURL(DOE_NODE_WEBGPU_PATH).href);
  } catch (err) {
    return { ok: false, detail: `cannot load Doe Node WebGPU bootstrap: ${err.message}` };
  }
  if (typeof mod.bootstrapNodeWebGPU !== 'function') {
    return { ok: false, detail: 'bootstrapNodeWebGPU export is missing' };
  }
  const bootstrap = await mod.bootstrapNodeWebGPU();
  if (!bootstrap?.ok) {
    return { ok: false, detail: bootstrap?.detail ?? 'bootstrap failed' };
  }
  if (!globalThis.navigator?.gpu) {
    return { ok: false, detail: 'navigator.gpu is absent after bootstrap' };
  }
  const adapter = await globalThis.navigator.gpu.requestAdapter();
  if (!adapter) return { ok: false, detail: 'requestAdapter returned null' };
  const device = await adapter.requestDevice();
  return { ok: true, device };
}

function shaderForSemantic(semantic, target, symbols, operation, state) {
  if (semantic === 'noop_unblock') return null;
  if (semantic === 'residual_add') {
    const n = float32View(symbols.get('output'), 'output').length;
    return {
      moduleId: 'csl-residual-add',
      code: `
@group(0) @binding(0) var<storage, read_write> input_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> residual_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> output_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= ${n}u) { return; }
  output_buf[i] = input_buf[i] + residual_buf[i];
}
`,
      symbols: ['input', 'residual', 'output'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'elementwise_identity') {
    const n = float32View(symbols.get('output'), 'output').length;
    return {
      moduleId: 'csl-elementwise-identity',
      code: `
@group(0) @binding(0) var<storage, read_write> input_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= ${n}u) { return; }
  output_buf[i] = input_buf[i];
}
`,
      symbols: ['input', 'output'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'gelu') {
    const n = float32View(symbols.get('output'), 'output').length;
    return {
      moduleId: 'csl-gelu',
      code: `
@group(0) @binding(0) var<storage, read_write> input_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> output_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let i = gid.x;
  if (i >= ${n}u) { return; }
  let x = input_buf[i];
  let t = 0.7978845608 * (x + 0.044715 * x * x * x);
  output_buf[i] = 0.5 * x * (1.0 + tanh(t));
}
`,
      symbols: ['input', 'output'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'rms_norm') {
    const n = float32View(symbols.get('output'), 'output').length;
    return {
      moduleId: 'csl-rms-norm',
      code: `
@group(0) @binding(0) var<storage, read_write> input_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> weight_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> output_buf: array<f32>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x > 0u) { return; }
  var sum_sq = 0.0;
  for (var i = 0u; i < ${n}u; i = i + 1u) {
    let v = input_buf[i];
    sum_sq = sum_sq + v * v;
  }
  let inv_rms = inverseSqrt(sum_sq / f32(${n}u) + 0.000001);
  for (var i = 0u; i < ${n}u; i = i + 1u) {
    output_buf[i] = input_buf[i] * inv_rms * (1.0 + weight_buf[i]);
  }
}
`,
      symbols: ['input', 'weight', 'output'],
      workgroups: 1,
    };
  }
  if (semantic === 'gather') {
    const n = float32View(symbols.get('output'), 'output').length;
    const tokensPerChunk = numericParam(target, 'tokens_per_chunk');
    const hiddenPerPe = numericParam(target, 'hidden_per_pe');
    const rowsPerPe = numericParam(target, 'rows_per_pe');
    return {
      moduleId: 'csl-gather',
      code: `
@group(0) @binding(0) var<storage, read_write> indices_buf: array<u32>;
@group(0) @binding(1) var<storage, read_write> table_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> output_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let hidden = idx % ${hiddenPerPe}u;
  let token = (idx / ${hiddenPerPe}u) % ${tokensPerChunk}u;
  let pe = idx / ${tokensPerChunk * hiddenPerPe}u;
  let token_id = indices_buf[pe * ${tokensPerChunk}u + token];
  let row_start = pe * ${rowsPerPe}u;
  if (token_id >= row_start && token_id < row_start + ${rowsPerPe}u) {
    let local_row = token_id - row_start;
    let table_idx = pe * ${rowsPerPe * hiddenPerPe}u + local_row * ${hiddenPerPe}u + hidden;
    output_buf[idx] = table_buf[table_idx];
  } else {
    output_buf[idx] = 0.0;
  }
}
`,
      symbols: ['indices', 'table', 'output'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'tiled_matmul') {
    const p = integerParam(target, 'P');
    const mt = integerParam(target, 'Mt');
    const kt = integerParam(target, 'Kt');
    const nt = integerParam(target, 'Nt');
    const n = float32View(symbols.get('c'), 'c').length;
    return {
      moduleId: 'csl-tiled-matmul',
      code: `
@group(0) @binding(0) var<storage, read_write> a_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> b_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> c_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let elem = gid.x;
  if (elem >= ${n}u) { return; }
  let c_tile = ${mt * nt}u;
  let dst_pe = elem / c_tile;
  let local = elem % c_tile;
  let px = dst_pe % ${p}u;
  let py = dst_pe / ${p}u;
  let i = local / ${nt}u;
  let j = local % ${nt}u;
  var acc = c_buf[elem];
  for (var step = 0u; step < ${p}u; step = step + 1u) {
    let a_base = (py * ${p}u + step) * ${mt * kt}u;
    let b_base = (step * ${p}u + px) * ${kt * nt}u;
    for (var k = 0u; k < ${kt}u; k = k + 1u) {
      acc = acc + a_buf[a_base + i * ${kt}u + k] * b_buf[b_base + j * ${kt}u + k];
    }
  }
  c_buf[elem] = acc;
}
`,
      symbols: ['a', 'b', 'c'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'rope') {
    const input = float32View(symbols.get('input'), 'input');
    const headDim = integerParam(target, 'head_dim', input.length);
    const numPairs = integerParam(target, 'num_pairs', Math.floor(headDim / 2));
    const interleaved = boolParam(target, 'interleaved', true);
    const peCount = inferPeCountFromSymbol(symbols.get('input'), headDim, 'input');
    const tableStride = float32View(symbols.get('cos_table'), 'cos_table').length >= peCount * numPairs;
    const n = peCount * numPairs;
    return {
      moduleId: 'csl-rope',
      code: `
@group(0) @binding(0) var<storage, read_write> input_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> cos_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> sin_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let pe = idx / ${numPairs}u;
  let pair = idx % ${numPairs}u;
  let table_base = ${tableStride ? 'pe * ' + numPairs + 'u' : '0u'};
  let cos_val = cos_buf[table_base + pair];
  let sin_val = sin_buf[table_base + pair];
  let dim0 = ${interleaved ? 'pair * 2u' : 'pair'};
  let dim1 = ${interleaved ? 'dim0 + 1u' : 'dim0 + ' + numPairs + 'u'};
  let base = pe * ${headDim}u;
  let x0 = input_buf[base + dim0];
  let x1 = input_buf[base + dim1];
  input_buf[base + dim0] = x0 * cos_val - x1 * sin_val;
  input_buf[base + dim1] = x0 * sin_val + x1 * cos_val;
}
`,
      symbols: ['input', 'cos_table', 'sin_table'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'kv_write') {
    const keyProj = float32View(symbols.get('key_proj'), 'key_proj');
    const headDim = integerParam(target, 'head_dim', keyProj.length);
    const peCount = inferPeCountFromSymbol(symbols.get('key_proj'), headDim, 'key_proj');
    const maxSeqLen = integerParam(target, 'max_seq_len');
    const positionStride = u32View(symbols.get('position'), 'position').length >= peCount;
    const n = peCount * headDim;
    return {
      moduleId: 'csl-kv-write',
      code: `
@group(0) @binding(0) var<storage, read_write> key_proj_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> val_proj_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> key_cache_buf: array<f32>;
@group(0) @binding(3) var<storage, read_write> val_cache_buf: array<f32>;
@group(0) @binding(4) var<storage, read_write> position_buf: array<u32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let pe = idx / ${headDim}u;
  let d = idx % ${headDim}u;
  let pos = position_buf[${positionStride ? 'pe' : '0u'}];
  if (pos >= ${maxSeqLen}u) { return; }
  let dst = (pe * ${maxSeqLen}u + pos) * ${headDim}u + d;
  key_cache_buf[dst] = key_proj_buf[idx];
  val_cache_buf[dst] = val_proj_buf[idx];
}
`,
      symbols: ['key_proj', 'val_proj', 'key_cache', 'val_cache', 'position'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'attention_tiled') {
    const info = ensureAttentionTiledState(target, symbols, state);
    const headDim = integerParam(target, 'head_dim');
    const blockSize = integerParam(target, 'block_size');
    const qLenPerPe = integerParamAlias(target, 'q_len_per_pe', 'q_len');
    const scale = numericParam(target, 'scale', 0.125);
    if (operation.functionName === 'finalize') {
      const n = float32View(symbols.get('output'), 'output').length;
      return {
        moduleId: 'csl-attention-tiled-finalize',
        code: `
@group(0) @binding(0) var<storage, read_write> output_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> l_state_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let row = idx / ${headDim}u;
  output_buf[idx] = output_buf[idx] / l_state_buf[row];
}
`,
        symbols: ['output', info.lState],
        stateSymbols: [info.lState],
        workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
      };
    }
    if (operation.functionName !== 'compute') {
      throw new Error(`unsupported attention_tiled function: ${operation.functionName}`);
    }
    const n = info.peCount * qLenPerPe;
    return {
      moduleId: 'csl-attention-tiled-compute',
      code: `
@group(0) @binding(0) var<storage, read_write> query_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> key_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> val_buf: array<f32>;
@group(0) @binding(3) var<storage, read_write> output_buf: array<f32>;
@group(0) @binding(4) var<storage, read_write> m_state_buf: array<f32>;
@group(0) @binding(5) var<storage, read_write> l_state_buf: array<f32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let row = gid.x;
  if (row >= ${n}u) { return; }
  let pe = row / ${qLenPerPe}u;
  let qi = row % ${qLenPerPe}u;
  let query_base = pe * ${qLenPerPe * headDim}u + qi * ${headDim}u;
  let kv_base = pe * ${blockSize * headDim}u;
  let out_base = query_base;
  var m_i = m_state_buf[row];
  var l_i = l_state_buf[row];
  var block_max = ${F32_NEG_MAX};
  for (var bi = 0u; bi < ${blockSize}u; bi = bi + 1u) {
    var score = 0.0;
    for (var d = 0u; d < ${headDim}u; d = d + 1u) {
      score = score + query_buf[query_base + d] * key_buf[kv_base + bi * ${headDim}u + d];
    }
    score = score * ${scale};
    if (score > block_max) { block_max = score; }
  }
  let m_new = max(m_i, block_max);
  let rescale = exp(m_i - m_new);
  l_i = l_i * rescale;
  for (var d = 0u; d < ${headDim}u; d = d + 1u) {
    output_buf[out_base + d] = output_buf[out_base + d] * rescale;
  }
  for (var bi = 0u; bi < ${blockSize}u; bi = bi + 1u) {
    var score = 0.0;
    for (var d = 0u; d < ${headDim}u; d = d + 1u) {
      score = score + query_buf[query_base + d] * key_buf[kv_base + bi * ${headDim}u + d];
    }
    let w = exp(score * ${scale} - m_new);
    l_i = l_i + w;
    for (var d = 0u; d < ${headDim}u; d = d + 1u) {
      output_buf[out_base + d] = output_buf[out_base + d] + w * val_buf[kv_base + bi * ${headDim}u + d];
    }
  }
  m_state_buf[row] = m_new;
  l_state_buf[row] = l_i;
}
`,
      symbols: ['query', 'key', 'val', 'output', info.mState, info.lState],
      stateSymbols: [info.mState, info.lState],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'attention_decode') {
    const headDim = integerParam(target, 'head_dim');
    const kvChunk = integerParam(target, 'kv_chunk');
    const scale = numericParam(target, 'scale', 0.125);
    const peCount = inferPeCountFromSymbol(symbols.get('query'), headDim, 'query');
    const n = float32View(symbols.get('output'), 'output').length;
    const positionStride = u32View(symbols.get('position'), 'position').length >= peCount;
    const windowStride = u32View(symbols.get('sliding_window'), 'sliding_window').length >= peCount;
    return {
      moduleId: 'csl-attention-decode',
      code: `
@group(0) @binding(0) var<storage, read_write> query_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> key_buf: array<f32>;
@group(0) @binding(2) var<storage, read_write> val_buf: array<f32>;
@group(0) @binding(3) var<storage, read_write> output_buf: array<f32>;
@group(0) @binding(4) var<storage, read_write> position_buf: array<u32>;
@group(0) @binding(5) var<storage, read_write> window_buf: array<u32>;
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let q_pe = idx / ${headDim}u;
  let out_d = idx % ${headDim}u;
  let query_base = q_pe * ${headDim}u;
  let current_pos = position_buf[${positionStride ? 'q_pe' : '0u'}];
  let window = window_buf[${windowStride ? 'q_pe' : '0u'}];
  var global_max = ${F32_NEG_MAX};
  for (var pe = 0u; pe < ${peCount}u; pe = pe + 1u) {
    for (var kv = 0u; kv < ${kvChunk}u; kv = kv + 1u) {
      let abs_key = pe * ${kvChunk}u + kv;
      if (window > 0u && current_pos >= window && abs_key < current_pos - window + 1u) { continue; }
      let kv_base = (pe * ${kvChunk}u + kv) * ${headDim}u;
      var score = 0.0;
      for (var d = 0u; d < ${headDim}u; d = d + 1u) {
        score = score + query_buf[query_base + d] * key_buf[kv_base + d];
      }
      score = score * ${scale};
      if (score > global_max) { global_max = score; }
    }
  }
  var global_sum = 0.0;
  for (var pe = 0u; pe < ${peCount}u; pe = pe + 1u) {
    for (var kv = 0u; kv < ${kvChunk}u; kv = kv + 1u) {
      let abs_key = pe * ${kvChunk}u + kv;
      if (window > 0u && current_pos >= window && abs_key < current_pos - window + 1u) { continue; }
      let kv_base = (pe * ${kvChunk}u + kv) * ${headDim}u;
      var score = 0.0;
      for (var d = 0u; d < ${headDim}u; d = d + 1u) {
        score = score + query_buf[query_base + d] * key_buf[kv_base + d];
      }
      global_sum = global_sum + exp(score * ${scale} - global_max);
    }
  }
  var out = 0.0;
  for (var kv = 0u; kv < ${kvChunk}u; kv = kv + 1u) {
    let abs_key = q_pe * ${kvChunk}u + kv;
    if (window > 0u && current_pos >= window && abs_key < current_pos - window + 1u) { continue; }
    let kv_base = (q_pe * ${kvChunk}u + kv) * ${headDim}u;
    var score = 0.0;
    for (var d = 0u; d < ${headDim}u; d = d + 1u) {
      score = score + query_buf[query_base + d] * key_buf[kv_base + d];
    }
    let w = exp(score * ${scale} - global_max) / global_sum;
    out = out + w * val_buf[kv_base + out_d];
  }
  output_buf[idx] = out;
}
`,
      symbols: ['query', 'key', 'val', 'output', 'position', 'sliding_window'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'fused_gemv_dequant') {
    const width = integerParam(target, 'width');
    const height = integerParam(target, 'height', 1);
    const outDimPerPe = integerParam(target, 'out_dim_per_pe');
    const inDimPerPe = integerParam(target, 'in_dim_per_pe');
    const numBlocksPerRow = integerParam(target, 'num_blocks_per_row');
    const n = width * height * outDimPerPe;
    const weightBytesPerPe = outDimPerPe * numBlocksPerRow * Q4K_BLOCK_BYTES;
    return {
      moduleId: 'csl-fused-gemv-dequant',
      code: `
@group(0) @binding(0) var<storage, read_write> activation_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> weight_buf: array<u32>;
@group(0) @binding(2) var<storage, read_write> output_buf: array<f32>;
fn load_u8(byte_offset: u32) -> u32 {
  let word = weight_buf[byte_offset / 4u];
  let shift = (byte_offset % 4u) * 8u;
  return (word >> shift) & 0xffu;
}
fn load_f16(byte_offset: u32) -> f32 {
  let lo = load_u8(byte_offset);
  let hi = load_u8(byte_offset + 1u);
  return unpack2x16float(lo | (hi << 8u)).x;
}
@compute @workgroup_size(${WEBGPU_WORKGROUP_SIZE})
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  let idx = gid.x;
  if (idx >= ${n}u) { return; }
  let row = idx % ${outDimPerPe}u;
  let pe = idx / ${outDimPerPe}u;
  let x = pe % ${width}u;
  let y = pe / ${width}u;
  var prefix = 0.0;
  for (var sx = 0u; sx <= x; sx = sx + 1u) {
    let src_pe = y * ${width}u + sx;
    let act_base = src_pe * ${inDimPerPe}u;
    let weight_base = src_pe * ${weightBytesPerPe}u + row * ${numBlocksPerRow * Q4K_BLOCK_BYTES}u;
    var partial = 0.0;
    for (var block = 0u; block < ${numBlocksPerRow}u; block = block + 1u) {
      let block_base = weight_base + block * ${Q4K_BLOCK_BYTES}u;
      let scale = load_f16(block_base);
      let data_off = block_base + 16u;
      let act_off = act_base + block * ${QK_K}u;
      for (var i = 0u; i < 128u; i = i + 1u) {
        let byte = load_u8(data_off + i);
        partial = partial + f32(byte & 0x0fu) * scale * activation_buf[act_off + i * 2u];
        partial = partial + f32(byte >> 4u) * scale * activation_buf[act_off + i * 2u + 1u];
      }
    }
    prefix = prefix + partial;
  }
  output_buf[idx] = prefix;
}
`,
      symbols: ['activation', 'weight', 'output'],
      workgroups: Math.max(1, Math.ceil(n / WEBGPU_WORKGROUP_SIZE)),
    };
  }
  if (semantic === 'sample') {
    const width = integerParam(target, 'width');
    const chunkSize = integerParam(target, 'chunk_size');
    const temperature = numericParam(target, 'temperature', 1.0);
    const softcap = numericParam(target, 'softcap', 0.0);
    return {
      moduleId: 'csl-sample',
      code: `
@group(0) @binding(0) var<storage, read_write> logits_buf: array<f32>;
@group(0) @binding(1) var<storage, read_write> tokens_buf: array<u32>;
@compute @workgroup_size(1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
  if (gid.x > 0u) { return; }
  var best_val = ${F32_NEG_MAX};
  var best_idx = 0u;
  for (var pe = 0u; pe < ${width}u; pe = pe + 1u) {
    for (var i = 0u; i < ${chunkSize}u; i = i + 1u) {
      let idx = pe * ${chunkSize}u + i;
      var value = logits_buf[idx];
      if (${softcap !== 0.0 ? 'true' : 'false'}) { value = ${softcap} * tanh(value / ${softcap}); }
      value = value / ${temperature};
      if (value > best_val) {
        best_val = value;
        best_idx = idx;
      }
    }
  }
  for (var pe = 0u; pe < ${width}u; pe = pe + 1u) {
    tokens_buf[pe] = 0u;
  }
  tokens_buf[${Math.max(0, width - 1)}u] = best_idx;
}
`,
      symbols: ['logits', 'tokens'],
      workgroups: 1,
    };
  }
  throw new Error(`unsupported WebGPU shader semantic: ${semantic}`);
}

function ensureAttentionTiledState(target, symbols, state) {
  const output = float32View(symbols.get('output'), 'output');
  const headDim = integerParam(target, 'head_dim');
  const qLenPerPe = integerParamAlias(target, 'q_len_per_pe', 'q_len');
  const peCount = output.length / (qLenPerPe * headDim);
  if (!Number.isInteger(peCount)) {
    throw new Error('attention_tiled output length does not divide into PE-local rows');
  }
  const stateElements = peCount * qLenPerPe;
  f32State(state, targetStateKey(target, 'm_state'), stateElements);
  f32State(state, targetStateKey(target, 'l_state'), stateElements);
  return {
    mState: targetStateKey(target, 'm_state'),
    lState: targetStateKey(target, 'l_state'),
    peCount,
  };
}

function createWebGpuBuffer(device, bytes) {
  const size = Math.max(BYTES_PER_WORD, bytes.byteLength);
  const buffer = device.createBuffer({
    size,
    usage: GPUBufferUsage.STORAGE |
      GPUBufferUsage.COPY_DST |
      GPUBufferUsage.COPY_SRC,
  });
  if (bytes.byteLength > 0) {
    device.queue.writeBuffer(buffer, 0, bytes);
  }
  return { buffer, size };
}

async function createWebGpuBuffers(device, symbols) {
  const buffers = new Map();
  for (const [name, symbol] of symbols) {
    buffers.set(name, createWebGpuBuffer(device, symbol.bytes));
  }
  return buffers;
}

function ensureWebGpuStateBuffers(device, buffers, state, names) {
  for (const name of names) {
    const entry = state.get(name);
    if (!entry) throw new Error(`missing WebGPU state entry: ${name}`);
    if (!buffers.has(name)) {
      buffers.set(name, createWebGpuBuffer(device, entry.bytes));
    }
  }
}

async function writeWebGpuSymbol(device, buffers, name, bytes) {
  const entry = buffers.get(name);
  if (!entry) throw new Error(`missing WebGPU symbol buffer: ${name}`);
  device.queue.writeBuffer(entry.buffer, 0, bytes);
  await device.queue.onSubmittedWorkDone?.();
}

async function readWebGpuSymbol(device, buffers, name, byteLength) {
  const entry = buffers.get(name);
  if (!entry) throw new Error(`missing WebGPU symbol buffer: ${name}`);
  const readback = device.createBuffer({
    size: Math.max(BYTES_PER_WORD, byteLength),
    usage: GPUBufferUsage.COPY_DST | GPUBufferUsage.MAP_READ,
  });
  const encoder = device.createCommandEncoder();
  encoder.copyBufferToBuffer(entry.buffer, 0, readback, 0, byteLength);
  device.queue.submit([encoder.finish()]);
  await readback.mapAsync(GPUMapMode.READ);
  const bytes = new Uint8Array(readback.getMappedRange().slice(0, byteLength));
  readback.unmap();
  return bytes;
}

async function executeLaunchWebGpu(device, buffers, symbols, state, target, operation, shaderModules) {
  const shader = shaderForSemantic(target.semantic, target, symbols, operation, state);
  if (!shader) return;
  ensureWebGpuStateBuffers(device, buffers, state, shader.stateSymbols ?? []);
  const module = device.createShaderModule({ code: shader.code });
  const pipeline = device.createComputePipeline({
    layout: 'auto',
    compute: { module, entryPoint: 'main' },
  });
  const entries = shader.symbols.map((name, binding) => ({
    binding,
    resource: { buffer: buffers.get(name).buffer },
  }));
  const bindGroup = device.createBindGroup({
    layout: pipeline.getBindGroupLayout(0),
    entries,
  });
  const encoder = device.createCommandEncoder();
  const pass = encoder.beginComputePass();
  pass.setPipeline(pipeline);
  pass.setBindGroup(0, bindGroup);
  pass.dispatchWorkgroups(shader.workgroups);
  pass.end();
  device.queue.submit([encoder.finish()]);
  await device.queue.onSubmittedWorkDone?.();
  shaderModules.push({
    moduleId: shader.moduleId,
    backend: 'webgpu',
    semantic: target.semantic,
    sha256: sha256Bytes(Buffer.from(shader.code, 'utf-8')),
  });
}

function symbolReceipts(symbols) {
  return Array.from(symbols.values()).map((symbol) => ({
    name: symbol.name,
    byteLength: symbol.bytes.byteLength,
    sha256: sha256Bytes(symbol.bytes),
  }));
}

function stateReceipts(state) {
  return Array.from(state.values()).map((entry) => ({
    name: entry.name,
    byteLength: entry.bytes.byteLength,
    sha256: sha256Bytes(entry.bytes),
  }));
}

function kernelTraceFabric(target) {
  const cp = target.compileParams || {};
  if (Number.isInteger(cp.viz_fabric_width) && Number.isInteger(cp.viz_fabric_height)
      && cp.viz_fabric_width > 0 && cp.viz_fabric_height > 0) {
    return { width: cp.viz_fabric_width, height: cp.viz_fabric_height };
  }
  if (target.semantic === 'tiled_matmul') {
    const P = integerParam(target, 'P');
    return { width: P, height: P };
  }
  const width = Math.max(1, Number(cp.width ?? 1));
  const height = Math.max(1, Number(cp.height ?? 1));
  return { width, height };
}

function kernelTraceOutputSpec(target) {
  const cp = target.compileParams || {};
  const baseSpec = (() => {
    switch (target.semantic) {
      case 'tiled_matmul': return { name: 'c', elementsPerPe: integerParam(target, 'Mt') * integerParam(target, 'Nt') };
      case 'fused_gemv_dequant': return { name: 'output', elementsPerPe: integerParam(target, 'out_dim_per_pe') };
      case 'attention_tiled': return { name: 'output', elementsPerPe: integerParamAlias(target, 'q_len_per_pe', 'q_len') * integerParam(target, 'head_dim') };
      case 'attention_decode': return { name: 'output', elementsPerPe: integerParam(target, 'head_dim') };
      case 'rope': return { name: 'input', elementsPerPe: integerParam(target, 'head_dim', 1) };
      case 'rms_norm':
      case 'residual_add':
      case 'gelu':
      case 'elementwise_identity':
      case 'gather':
        return { name: 'output', elementsPerPe: 1 };
      case 'kv_write': return { name: 'key_cache', elementsPerPe: integerParam(target, 'head_dim') };
      case 'sample': return { name: 'tokens', elementsPerPe: 1 };
      default: return { name: null, elementsPerPe: 1 };
    }
  })();
  if (Number.isInteger(cp.viz_elements_per_pe) && cp.viz_elements_per_pe > 0) {
    return { name: baseSpec.name, elementsPerPe: cp.viz_elements_per_pe };
  }
  return baseSpec;
}

function summarizeBufferRange(buf, base, len) {
  if (!buf || len <= 0) return { mean: 0, absMax: 0, head: [] };
  const view = new Float32Array(buf.buffer, buf.byteOffset + base * BYTES_PER_WORD, len);
  let sum = 0;
  let absMax = 0;
  for (let i = 0; i < len; i += 1) {
    const v = view[i];
    if (Number.isFinite(v)) {
      sum += v;
      const a = Math.abs(v);
      if (a > absMax) absMax = a;
    }
  }
  const headLen = Math.min(4, len);
  const head = Array.from(view.subarray(0, headLen)).map((v) => Number(v.toFixed(4)));
  return { mean: Number((sum / Math.max(1, len)).toFixed(4)), absMax: Number(absMax.toFixed(4)), head };
}

function buildPeDelta(symbols, name, fabric, elementsPerPe) {
  if (!name) return [];
  const sym = symbols.get(name);
  if (!sym) return [];
  const out = [];
  for (let y = 0; y < fabric.height; y += 1) {
    for (let x = 0; x < fabric.width; x += 1) {
      const pe = y * fabric.width + x;
      const base = pe * elementsPerPe;
      out.push({
        pe: [x, y],
        buffers: { [name]: summarizeBufferRange(sym.bytes, base, elementsPerPe) },
      });
    }
  }
  return out;
}

async function runEmulator(inputPath, input, requestedBackend, options = {}) {
  const inspection = inspectSources(input);
  const symbols = buildSymbolTable(input);
  const state = new Map();
  const fixtures = fixtureMap(input);
  const operations = [];
  const unsupported = [];
  const shaderModules = [];
  const inputSha = sha256File(inputPath);
  const kernelTracePhases = options.kernelTracePath ? [] : null;
  let firstFabric = null;

  let executedBackend = requestedBackend;
  let webgpu = null;
  if (requestedBackend === 'auto' || requestedBackend === 'webgpu') {
    webgpu = await bootstrapWebGpu();
    if (!webgpu.ok && requestedBackend === 'webgpu') {
      unsupported.push(blocker('webgpu_unavailable', webgpu.detail));
      executedBackend = 'none';
    } else if (!webgpu.ok) {
      executedBackend = 'cpu';
    } else {
      executedBackend = 'webgpu';
    }
  }
  if (requestedBackend === 'cpu') executedBackend = 'cpu';

  let webgpuBuffers = null;
  if (executedBackend === 'webgpu') {
    webgpuBuffers = await createWebGpuBuffers(webgpu.device, symbols);
  }

  let blocked = unsupported.length > 0;
  const pushBlocked = (operation, item) => {
    unsupported.push(item);
    operations.push({
      operationId: operation.operationId,
      kind: operation.kind,
      status: 'blocked',
      backend: 'none',
      blockerCode: item.code,
      ...(operation.deviceSymbol ? { deviceSymbol: operation.deviceSymbol } : {}),
      ...(operation.functionName ? { functionName: operation.functionName } : {}),
    });
    blocked = true;
  };

  for (const operation of input.operationGraph.operations) {
    if (blocked) {
      operations.push({
        operationId: operation.operationId,
        kind: operation.kind,
        status: 'skipped',
        backend: 'none',
      });
      continue;
    }
    if (operation.kind === 'memcpy_h2d') {
      const name = symbolNameForMemcpy(operation);
      const expectedBytes = operationByteLength(operation);
      const fixture = fixtures.byOperation.get(operation.operationId)
        ?? fixtures.bySymbol.get(name);
      if (!fixture) {
        pushBlocked(operation, blocker(
          input.hostInputs?.mode === 'doppler_rdrr'
            ? 'doppler_rdrr_binding_not_implemented'
            : 'fixture_missing',
          `missing H2D fixture for ${name}`,
          { operationId: operation.operationId, deviceSymbol: name },
        ));
        continue;
      }
      if (fixture.bytes.byteLength !== expectedBytes) {
        pushBlocked(operation, blocker(
          'fixture_byte_length_mismatch',
          `fixture for ${name} has ${fixture.bytes.byteLength} bytes, expected ${expectedBytes}`,
          { operationId: operation.operationId, deviceSymbol: name },
        ));
        continue;
      }
      symbols.get(name).bytes.set(fixture.bytes);
      if (executedBackend === 'webgpu') {
        await writeWebGpuSymbol(webgpu.device, webgpuBuffers, name, fixture.bytes);
      }
      operations.push({
        operationId: operation.operationId,
        kind: operation.kind,
        status: 'succeeded',
        backend: 'host',
        deviceSymbol: name,
        byteLength: expectedBytes,
        sha256: sha256Bytes(fixture.bytes),
      });
      continue;
    }
    if (operation.kind === 'memcpy_d2h') {
      const name = symbolNameForMemcpy(operation);
      const byteLength = operationByteLength(operation);
      let bytes = symbols.get(name).bytes.slice(0, byteLength);
      if (executedBackend === 'webgpu') {
        bytes = await readWebGpuSymbol(webgpu.device, webgpuBuffers, name, byteLength);
        symbols.set(name, { name, bytes });
      }
      const outputFile = writeD2hOutputFile(
        options.d2hOutDir,
        operation,
        name,
        bytes,
      );
      operations.push({
        operationId: operation.operationId,
        kind: operation.kind,
        status: 'succeeded',
        backend: 'host',
        deviceSymbol: name,
        byteLength,
        sha256: sha256Bytes(bytes),
        ...(outputFile ? { outputFile } : {}),
      });
      continue;
    }
    if (operation.kind === 'launch') {
      const target = targetForLaunch(input, inspection, operation);
      if (!target || target.semantic === 'unsupported') {
        pushBlocked(operation, blocker(
          'unsupported_csl_launch_semantic',
          `unsupported launch ${operation.functionName} (target=${operation.target ?? '?'})`,
          {
            operationId: operation.operationId,
            functionName: operation.functionName,
          },
        ));
        continue;
      }
      try {
        const launchSymbols = bindSymbols(symbols, operation.symbolBindings);
        if (executedBackend === 'webgpu') {
          await executeLaunchWebGpu(
            webgpu.device,
            webgpuBuffers,
            launchSymbols,
            state,
            target,
            operation,
            shaderModules,
            operation.symbolBindings,
          );
        } else if (executedBackend === 'cpu') {
          executeLaunchCpu(launchSymbols, target, operation, state);
        } else {
          throw new Error('no executable backend selected');
        }
        operations.push({
          operationId: operation.operationId,
          kind: operation.kind,
          status: 'succeeded',
          backend: executedBackend,
          functionName: operation.functionName,
          semantic: target.semantic,
        });
        if (kernelTracePhases) {
          const fabric = kernelTraceFabric(target);
          if (!firstFabric) firstFabric = fabric;
          const outputSpec = kernelTraceOutputSpec(target);
          const traceSymbolName = operation.symbolBindings?.[outputSpec.name] ?? outputSpec.name;
          kernelTracePhases.push({
            phase: target.semantic,
            label: `launch ${operation.operationId} → ${target.name} (${target.semantic}, fabric ${fabric.width}×${fabric.height}, fn ${operation.functionName ?? 'compute'})`,
            fabric,
            peDelta: buildPeDelta(symbols, traceSymbolName, fabric, outputSpec.elementsPerPe),
            flows: [],
            launch: {
              operationId: operation.operationId,
              targetName: target.name,
              functionName: operation.functionName,
              outputSymbol: traceSymbolName,
              elementsPerPe: outputSpec.elementsPerPe,
            },
          });
        }
      } catch (err) {
        pushBlocked(operation, blocker(
          'launch_execution_failed',
          err.message,
          {
            operationId: operation.operationId,
            functionName: operation.functionName,
          },
        ));
      }
      continue;
    }
    pushBlocked(operation, blocker(
      'unsupported_operation_kind',
      `unsupported operation kind: ${operation.kind}`,
      { operationId: operation.operationId },
    ));
  }

  if (executedBackend === 'webgpu') {
    for (const [name, symbol] of symbols) {
      if (symbol.bytes.byteLength > 0) {
        const bytes = await readWebGpuSymbol(
          webgpu.device,
          webgpuBuffers,
          name,
          symbol.bytes.byteLength,
        );
        symbols.set(name, { name, bytes });
      }
    }
    for (const [name, entry] of state) {
      if (entry.bytes.byteLength > 0) {
        const bytes = await readWebGpuSymbol(
          webgpu.device,
          webgpuBuffers,
          name,
          entry.bytes.byteLength,
        );
        state.set(name, { name, bytes });
      }
    }
  }

  const receipt = {
    schemaVersion: 1,
    artifactKind: 'csl_webgpu_emulator_result',
    contract: 'csl_source_to_webgpu_semantic_emulation',
    input: {
      path: repoRelative(inputPath),
      sha256: inputSha,
      operationGraphSha256: input.operationGraphSha256,
      artifactKind: input.artifactKind,
      claimScope: input.claimScope,
    },
    requestedBackend,
    executedBackend,
    status: blocked ? 'blocked' : 'succeeded',
    sourceInspection: {
      compileTargetCount: inspection.compileTargetCount,
      exportedSymbolCount: inspection.exportedSymbolCount,
      operationCount: inspection.operationCount,
      compileTargets: inspection.compileTargets.map((target) => ({
        name: target.name,
        ...(target.pattern ? { pattern: target.pattern } : {}),
        layoutSha256: target.layoutSha256,
        peProgramSha256: target.peProgramSha256,
        semantic: target.semantic,
      })),
    },
    execution: {
      operations,
      symbols: symbolReceipts(symbols),
      state: stateReceipts(state),
      shaderModules,
    },
    unsupported,
    resultSha256: RESULT_PLACEHOLDER_HASH,
  };
  receipt.resultSha256 = resultHash(receipt);
  if (kernelTracePhases && options.kernelTracePath) {
    const introPhase = {
      phase: 'init',
      label: `Emulator chain trace · ${kernelTracePhases.length} launches · backend=${executedBackend}`,
      fabric: firstFabric || { width: 1, height: 1 },
      peDelta: [],
      flows: [],
    };
    const trace = {
      schemaVersion: 1,
      artifactKind: 'csl_kernel_trace',
      kernel: {
        pattern: 'emulator_chain',
        params: { launches: kernelTracePhases.length, backend: executedBackend },
        fabric: firstFabric || { width: 1, height: 1 },
        buffers: ['output'],
        semantics: 'Chain trace from a real csl-webgpu-emulator run. Each phase is one launch event with post-launch per-PE output summary at the kernel\'s active fabric rectangle. Source: bench/tools/run_csl_webgpu_emulator.mjs --kernel-trace.',
      },
      notWhat: 'Per-launch coarse-grain animation. Within-kernel broadcast/fmac/reduce steps are not decomposed; use bench/tools/build_csl_kernel_trace.mjs for fine-grained per-step traces.',
      phases: [introPhase, ...kernelTracePhases],
    };
    mkdirSync(dirname(options.kernelTracePath), { recursive: true });
    writeFileSync(options.kernelTracePath, JSON.stringify(trace), 'utf-8');
    process.stderr.write(`wrote kernel trace: ${repoRelative(options.kernelTracePath)} (${trace.phases.length} phases)\n`);
  }
  return receipt;
}

async function main() {
  const args = parseArgs(process.argv);
  const inputPath = resolve(args.input);
  const outPath = resolve(args.out);
  const input = readJson(inputPath);
  if (input.artifactKind !== 'csl_webgpu_emulator_input') {
    throw new Error(`not a CSL WebGPU emulator input: ${inputPath}`);
  }
  const receipt = await runEmulator(
    inputPath,
    input,
    args.backend,
    {
      d2hOutDir: args.d2hOutDir,
      kernelTracePath: args.kernelTrace ? resolve(args.kernelTrace) : null,
    },
  );
  mkdirSync(dirname(outPath), { recursive: true });
  writeFileSync(outPath, `${JSON.stringify(receipt, null, 2)}\n`, 'utf-8');
  process.stdout.write(
    `wrote CSL WebGPU emulator result: ${repoRelative(outPath)} ${receipt.status}\n`,
  );
  return receipt.status === 'succeeded' ? 0 : 1;
}

main()
  .then((code) => {
    process.exitCode = code;
  })
  .catch((err) => {
    process.stderr.write(`FAIL ${err && err.message ? err.message : err}\n`);
    process.exitCode = 1;
  });
