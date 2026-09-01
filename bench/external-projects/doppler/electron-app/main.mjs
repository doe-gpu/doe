import 'electron';
import { pathToFileURL } from 'node:url';

const exportTool = process.env.DOE_DOPPLER_QUALIFICATION_EXPORT_TOOL;
if (!exportTool) {
  throw new Error('DOE_DOPPLER_QUALIFICATION_EXPORT_TOOL is required.');
}

const workloadArgsStart = process.argv.indexOf('--doppler-root');
if (workloadArgsStart < 0) {
  throw new Error('Electron qualification workload arguments are missing.');
}
process.argv = [process.argv[0], exportTool, ...process.argv.slice(workloadArgsStart)];

await import(pathToFileURL(exportTool).href);
