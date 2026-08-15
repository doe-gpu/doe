import { app } from 'electron';
import { register } from 'node:module';

try {
  register(new URL('../provider-loader.mjs', import.meta.url), import.meta.url);
  await import('../run-workload.mjs');
  app.exit(0);
} catch (error) {
  process.stderr.write(`${error?.stack ?? error}\n`);
  app.exit(1);
}
