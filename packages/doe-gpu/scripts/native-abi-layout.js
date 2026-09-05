// Compare bridge layouts with the same pinned C header used by the Zig runtime.
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const LAYOUTS = [
  ['WGPUComputePassTimestampWrites', 'WGPUPassTimestampWrites',
    ['nextInChain', 'querySet', 'beginningOfPassWriteIndex', 'endOfPassWriteIndex']],
  ['WGPURenderPassTimestampWrites', 'WGPUPassTimestampWrites',
    ['nextInChain', 'querySet', 'beginningOfPassWriteIndex', 'endOfPassWriteIndex']],
  ['WGPURenderPassMaxDrawCount', 'WGPURenderPassMaxDrawCount', ['chain', 'maxDrawCount']],
  ['WGPUComputePassDescriptor', 'WGPUComputePassDescriptor', ['nextInChain', 'label', 'timestampWrites']],
  ['WGPURenderPassDescriptor', 'WGPURenderPassDescriptor',
    ['nextInChain', 'label', 'colorAttachmentCount', 'colorAttachments', 'depthStencilAttachment', 'occlusionQuerySet', 'timestampWrites']],
];

function checkNativeAbiLayouts({ compiler, includeDir, bridgeHeader, upstreamHeader }) {
  const directory = mkdtempSync(join(tmpdir(), 'doe-native-abi-'));
  try {
    const observed = [bridgeHeader, upstreamHeader].map((header, side) => {
      const output = join(directory, `layout-${side}`);
      const rows = LAYOUTS.map((layout) => {
        const name = layout[side];
        const values = [`sizeof(${name})`, ...layout[2].map((field) => `offsetof(${name}, ${field})`)];
        return `printf("${values.map(() => '%zu').join(' ')}\\n", ${values.join(', ')});`;
      });
      const source = `#include <stdio.h>\n#include <stddef.h>\n#include ${JSON.stringify(header)}\nint main(void) { ${rows.join('\n')} return 0; }\n`;
      execFileSync(compiler, ['-std=c11', `-I${includeDir}`, '-x', 'c', '-', '-o', output], { input: source, stdio: ['pipe', 'pipe', 'pipe'] });
      return execFileSync(output, { encoding: 'utf8' }).trim().split('\n');
    });
    for (const [index, layout] of LAYOUTS.entries()) {
      if (observed[0][index] !== observed[1][index]) {
        throw new Error(`Native ABI mismatch for ${layout[0]}: bridge ${observed[0][index]}; pinned header ${observed[1][index]}`);
      }
    }
  } finally { rmSync(directory, { recursive: true, force: true }); }
}

export { checkNativeAbiLayouts };
