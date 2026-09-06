import { runFirstKernel } from './first-kernel.js';

console.log(JSON.stringify(await runFirstKernel('node'), null, 2));
