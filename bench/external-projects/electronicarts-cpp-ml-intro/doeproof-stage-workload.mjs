import { register } from 'node:module';

register('./doeproof-pngjs-loader.mjs', import.meta.url);
await import('./mnist-stage-diagnostic.mjs');
