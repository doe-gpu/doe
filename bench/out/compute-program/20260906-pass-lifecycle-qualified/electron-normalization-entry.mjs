try {
await import('./normalization.mjs');
(await import('electron')).app.exit(0);
} catch (error) { console.error(error); (await import('electron')).app.exit(1); }
