import { runFirstKernel } from './first-kernel.js';

console.log(JSON.stringify(await runFirstKernel('bun'), null, 2));
