#!/usr/bin/env node

// README benchmark chart generator.
//
// Generates the committed SVG evidence charts used by the top-level and
// package README surfaces from a single JSON data file and artifact-backed
// compare reports.

import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = path.resolve(__dirname, '..');
const CLAIMS_PATH = path.join(REPO_ROOT, 'assets', 'readme', 'benchmark-claims.json');
const OUTPUT_DIR = path.join(REPO_ROOT, 'assets', 'readme');

const SVG_THEME = Object.freeze({
  palette: Object.freeze({
    bg: '#ffffff',
    panel: '#ffffff',
    panelAlt: '#fafafa',
    border: '#111111',
    text: '#111111',
    muted: '#4b5563',
    grid: '#e5e7eb',
    accent: '#8b5cf6',           // Purple
    doe: '#3b82f6',              // Blue
    incumbent: '#f87171',        // Light Red
    mixed: '#9ca3af',
    positive: '#8b5cf6',
    bad: '#ef4444'
  }),
  fonts: Object.freeze({
    ui: 'Outfit, Inter, system-ui, -apple-system, sans-serif',
    mono: 'JetBrains Mono, Fira Code, SFMono-Regular, Consolas, monospace'
  }),
  stroke: Object.freeze({
    thin: 1.25,
    normal: 1.75
  }),
  radius: Object.freeze({
    panel: 6,
    badge: 4
  })
});

const FONT_UI = "Outfit, Inter, system-ui, -apple-system, sans-serif";
const FONT_MONO = "JetBrains Mono, Fira Code, SFMono-Regular, Consolas, monospace";
const CANVAS_PADDING = 14;
const CHART_WIDTH = 1340;
const HEADER_HEIGHT = 126;
const ROW_HEIGHT = 176;
const ROW_GAP = 18;
const FOOTER_HEIGHT = 60;
const PANEL_X = 24;
const PANEL_WIDTH = CHART_WIDTH - (PANEL_X * 2);
const LABEL_X = 48;
const TRACK_X = 322;
const TRACK_WIDTH = 774;
const SERIES_LABEL_WIDTH = 90;
const METRIC_BAR_X = TRACK_X + SERIES_LABEL_WIDTH;
const METRIC_BAR_WIDTH = 520;
const METRIC_VALUE_X = METRIC_BAR_X + METRIC_BAR_WIDTH + 12;
const VALUE_PILL_X = 1134;
const VALUE_PILL_WIDTH = 160;
const HEADER_PILL_X = 998;
const HEADER_PILL_WIDTH = 296;
const ROW_TIME_SCALE_PADDING = 1.04;
const ROW_COUNT_SCALE_PADDING = 1.12;
const BAR_HEIGHT = 12;
const BAR_GAP = 6;
const METRIC_GROUPS = Object.freeze([
  { key: 'p50', label: 'p50 ms', yOffset: 26, field: 'P50Ms', scale: 'time' },
  { key: 'p95', label: 'p95 ms', yOffset: 78, field: 'P95Ms', scale: 'time' }
]);

function escapeXml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll('\'', '&#39;');
}

function formatDelta(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return 'Mixed';
  }
  const prefix = numeric >= 0 ? '+' : '';
  return `${prefix}${numeric.toFixed(1)}%`;
}

function formatMs(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return 'n/a';
  }
  return `${numeric.toLocaleString('en-US', {
    minimumFractionDigits: 1,
    maximumFractionDigits: 1
  })} ms`;
}

function formatCount(value) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric)) {
    return 'n/a';
  }
  return `n=${numeric.toLocaleString('en-US')}`;
}

function makeSvgTextStyle() {
  const palette = SVG_THEME.palette;
  return `<defs><style>
  text { fill: ${palette.text}; font-family: ${FONT_UI}; letter-spacing: 0; }
  .ev-title { font-size: 30px; font-weight: 700; }
  .ev-subtitle { font-size: 14px; fill: ${palette.muted}; font-weight: 500; }
  .ev-node-title { font-size: 20px; font-weight: 700; }
  .ev-label { font-size: 12px; fill: ${palette.muted}; font-weight: 600; }
  .ev-mono { font-family: ${FONT_MONO}; }
</style></defs>`;
}

function renderCanvas(width, height) {
  return `<rect x="0" y="0" width="${width}" height="${height}" fill="${SVG_THEME.palette.bg}" />
  <rect x="${CANVAS_PADDING}" y="${CANVAS_PADDING}" width="${width - (CANVAS_PADDING * 2)}" height="${height - (CANVAS_PADDING * 2)}" rx="${SVG_THEME.radius.panel}" fill="${SVG_THEME.palette.panel}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />`;
}

function renderDefs() {
  return '';
}

function svgWrap(width, height, title, desc, body) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" role="img" aria-labelledby="chart-title chart-desc">
  <title id="chart-title">${escapeXml(title)}</title>
  <desc id="chart-desc">${escapeXml(desc)}</desc>
  ${makeSvgTextStyle()}
  ${renderCanvas(width, height)}
  ${body}
</svg>`;
}

function getChartHeight(rowCount) {
  return HEADER_HEIGHT + 30 + (rowCount * ROW_HEIGHT) + ((rowCount - 1) * ROW_GAP) + FOOTER_HEIGHT;
}

function readArtifactMetrics(relativeArtifactPath) {
  const artifactPath = path.join(REPO_ROOT, relativeArtifactPath);
  const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
  const baselineStats = artifact?.overall?.baselineStatsMs;
  const comparisonStats = artifact?.overall?.comparisonStatsMs;
  const deltaPercent = artifact?.overall?.deltaPercent;
  if (!baselineStats || !comparisonStats || !deltaPercent) {
    throw new Error(`Artifact ${relativeArtifactPath} is missing compare summary fields.`);
  }
  return Object.freeze({
    baselineCount: baselineStats.count,
    baselineP50Ms: baselineStats.p50Ms,
    baselineP95Ms: baselineStats.p95Ms,
    comparisonCount: comparisonStats.count,
    comparisonP50Ms: comparisonStats.p50Ms,
    comparisonP95Ms: comparisonStats.p95Ms,
    deltaP50Percent: deltaPercent.p50Percent,
    deltaP95Percent: deltaPercent.p95Percent
  });
}

function resolveChartRows(rows) {
  return rows.map((row) => {
    if (typeof row.status === 'string' && row.status.toLowerCase() === 'mixed') {
      return row;
    }
    if (typeof row.artifactPath !== 'string' || row.artifactPath.length === 0) {
      throw new Error(`Row ${row.label} is missing artifactPath.`);
    }
    return Object.freeze({
      ...row,
      metrics: readArtifactMetrics(row.artifactPath)
    });
  });
}

function getRowScaleState(row) {
  return Object.freeze({
    maxTime: Math.max(
      1,
      Number(row.metrics.baselineP50Ms),
      Number(row.metrics.comparisonP50Ms),
      Number(row.metrics.baselineP95Ms),
      Number(row.metrics.comparisonP95Ms)
    ) * ROW_TIME_SCALE_PADDING,
    maxCount: Math.max(
      1,
      Number(row.metrics.baselineCount),
      Number(row.metrics.comparisonCount)
    ) * ROW_COUNT_SCALE_PADDING
  });
}

function renderHeader(title, subtitle, width) {
  return `<text x="36" y="70" class="ev-title">${escapeXml(title)}</text>
<text x="36" y="102" class="ev-subtitle">${escapeXml(subtitle)}</text>
<rect x="${HEADER_PILL_X}" y="34" width="${HEADER_PILL_WIDTH}" height="38" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.panelAlt}" stroke="${SVG_THEME.palette.accent}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${HEADER_PILL_X + (HEADER_PILL_WIDTH / 2)}" y="58" text-anchor="middle" class="ev-label ev-mono" style="fill:${SVG_THEME.palette.accent}">BARS IN MS; LOWER IS BETTER</text>`;
}

function renderLegend(y) {
  return `<rect x="36" y="${y}" width="18" height="18" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.doe}" />
<text x="64" y="${y + 13}" font-size="13">Doe timing bars</text>
<rect x="250" y="${y}" width="18" height="18" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.incumbent}" />
<text x="278" y="${y + 13}" font-size="13">comparison timing bars</text>
<rect x="540" y="${y}" width="18" height="18" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.positive}" />
<text x="568" y="${y + 13}" font-size="13">summary pill = p50 and p95 faster summary</text>`;
}

function renderScaleNote(y) {
  return `<text x="${TRACK_X}" y="${y}" class="ev-label">Each lane scales its own bars; exact ms and sample counts are printed on the row.</text>`;
}

function getMetricValue(metrics, seriesKey, field) {
  return metrics[`${seriesKey}${field}`];
}

function renderMetricBlock(row, group, rowY, scaleState) {
  const trackY = rowY + group.yOffset;
  const maxValue = group.scale === 'time' ? scaleState.maxTime : scaleState.maxCount;
  const series = [
    {
      key: 'baseline',
      label: row.baselineLabel,
      fill: SVG_THEME.palette.doe
    },
    {
      key: 'comparison',
      label: row.comparisonLabel,
      fill: SVG_THEME.palette.incumbent
    }
  ];
  const labelY = trackY - 8;
  const markup = [
    `<text x="${TRACK_X}" y="${labelY}" class="ev-label ev-mono">${escapeXml(group.label)}</text>`
  ];

  for (const [seriesIndex, seriesEntry] of series.entries()) {
    const y = trackY + (seriesIndex * (BAR_HEIGHT + BAR_GAP));
    const value = Number(getMetricValue(row.metrics, seriesEntry.key, group.field));
    const width = Math.max(0, (METRIC_BAR_WIDTH * value) / maxValue);
    const valueLabel = group.scale === 'time' ? formatMs(value) : formatCount(value);
    markup.push(`<circle cx="${TRACK_X + 8}" cy="${y + 6}" r="4" fill="${seriesEntry.fill}" />
<text x="${TRACK_X + 20}" y="${y + 10}" font-size="11" font-weight="700">${escapeXml(seriesEntry.label)}</text>
<rect x="${METRIC_BAR_X}" y="${y}" width="${METRIC_BAR_WIDTH}" height="${BAR_HEIGHT}" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.panel}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<rect x="${METRIC_BAR_X + 1}" y="${y + 1}" width="${Math.max(0, width - 2)}" height="${BAR_HEIGHT - 2}" rx="${SVG_THEME.radius.badge}" fill="${seriesEntry.fill}" />
<text x="${METRIC_VALUE_X}" y="${y + 10}" class="ev-mono" font-size="11">${escapeXml(valueLabel)}</text>`);
  }

  return markup.join('\n');
}

function renderMeasuredRow(row, rowIndex) {
  const y = HEADER_HEIGHT + 30 + (rowIndex * (ROW_HEIGHT + ROW_GAP));
  const panelHeight = ROW_HEIGHT;
  const scaleState = getRowScaleState(row);
  const baselineSamples = formatCount(row.metrics.baselineCount);
  const comparisonSamples = formatCount(row.metrics.comparisonCount);
  return `<rect x="${PANEL_X}" y="${y}" width="${PANEL_WIDTH}" height="${panelHeight}" rx="${SVG_THEME.radius.panel}" fill="${SVG_THEME.palette.panelAlt}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${LABEL_X}" y="${y + 38}" class="ev-node-title">${escapeXml(row.label)}</text>
<rect x="${LABEL_X}" y="${y + 52}" width="176" height="30" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.accent}" fill-opacity="0.14" stroke="${SVG_THEME.palette.accent}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${LABEL_X + 16}" y="${y + 72}" class="ev-label" style="fill:${SVG_THEME.palette.accent}">${escapeXml(row.platform)}</text>
${METRIC_GROUPS.map((group) => renderMetricBlock(row, group, y, scaleState)).join('\n')}
<text x="${TRACK_X}" y="${y + 152}" class="ev-label">${escapeXml(`${row.baselineLabel} ${baselineSamples}`)}</text>
<text x="${TRACK_X + 148}" y="${y + 152}" class="ev-label">${escapeXml(`${row.comparisonLabel} ${comparisonSamples}`)}</text>
<rect x="${VALUE_PILL_X}" y="${y + 22}" width="${VALUE_PILL_WIDTH}" height="40" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.positive}" fill-opacity="0.14" stroke="${SVG_THEME.palette.positive}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${VALUE_PILL_X + (VALUE_PILL_WIDTH / 2)}" y="${y + 48}" text-anchor="middle" font-size="18" font-weight="700" style="fill:${SVG_THEME.palette.positive}">${escapeXml(formatDelta(row.metrics.deltaP50Percent))}</text>
<rect x="${VALUE_PILL_X}" y="${y + 72}" width="${VALUE_PILL_WIDTH}" height="34" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.panel}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${VALUE_PILL_X + (VALUE_PILL_WIDTH / 2)}" y="${y + 93}" text-anchor="middle" class="ev-label">${escapeXml(`p95 ${formatDelta(row.metrics.deltaP95Percent)}`)}</text>
<rect x="${VALUE_PILL_X}" y="${y + 116}" width="${VALUE_PILL_WIDTH}" height="28" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.panel}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${VALUE_PILL_X + (VALUE_PILL_WIDTH / 2)}" y="${y + 134}" text-anchor="middle" class="ev-label ev-mono">artifact-backed</text>`;
}

function renderMixedRow(row, rowIndex) {
  const y = HEADER_HEIGHT + 30 + (rowIndex * (ROW_HEIGHT + ROW_GAP));
  const panelHeight = ROW_HEIGHT;
  return `<rect x="${PANEL_X}" y="${y}" width="${PANEL_WIDTH}" height="${panelHeight}" rx="${SVG_THEME.radius.panel}" fill="${SVG_THEME.palette.panelAlt}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${LABEL_X}" y="${y + 38}" class="ev-node-title">${escapeXml(row.label)}</text>
<rect x="${LABEL_X}" y="${y + 52}" width="176" height="30" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.accent}" fill-opacity="0.14" stroke="${SVG_THEME.palette.accent}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${LABEL_X + 16}" y="${y + 72}" class="ev-label" style="fill:${SVG_THEME.palette.accent}">${escapeXml(row.platform)}</text>
<rect x="${TRACK_X}" y="${y + 28}" width="${TRACK_WIDTH}" height="118" rx="${SVG_THEME.radius.panel}" fill="${SVG_THEME.palette.panel}" stroke="${SVG_THEME.palette.border}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${TRACK_X + 24}" y="${y + 60}" font-size="18" font-weight="700">Mixed evidence</text>
<text x="${TRACK_X + 24}" y="${y + 86}" class="ev-subtitle">Current browser ORT results are not summarized as a single faster or slower timing claim.</text>
<text x="${TRACK_X + 24}" y="${y + 112}" class="ev-subtitle">The chart keeps this lane explicit instead of forcing a misleading bar summary.</text>
<rect x="${VALUE_PILL_X}" y="${y + 54}" width="${VALUE_PILL_WIDTH}" height="54" rx="${SVG_THEME.radius.badge}" fill="${SVG_THEME.palette.mixed}" fill-opacity="0.14" stroke="${SVG_THEME.palette.mixed}" stroke-width="${SVG_THEME.stroke.thin}" />
<text x="${VALUE_PILL_X + (VALUE_PILL_WIDTH / 2)}" y="${y + 87}" text-anchor="middle" font-size="18" font-weight="700" style="fill:${SVG_THEME.palette.mixed}">MIXED</text>`;
}

function renderChart(chartConfig) {
  const rows = resolveChartRows(Array.isArray(chartConfig.rows) ? chartConfig.rows : []);
  const height = getChartHeight(rows.length);
  const rowMarkup = rows.map((row, rowIndex) => {
    if (typeof row.status === 'string' && row.status.toLowerCase() === 'mixed') {
      return renderMixedRow(row, rowIndex);
    }
    return renderMeasuredRow(row, rowIndex);
  }).join('\n');
  const legendY = height - 40;

  return svgWrap(
    CHART_WIDTH,
    height,
    chartConfig.title,
    chartConfig.caption ?? chartConfig.subtitle,
    `${renderDefs()}${renderHeader(chartConfig.title, chartConfig.subtitle, CHART_WIDTH)}
${renderScaleNote(148)}
${rowMarkup}
${renderLegend(legendY)}`
  );
}

function writeSvg(outputName, svgContent) {
  const outputPath = path.join(OUTPUT_DIR, outputName);
  fs.writeFileSync(outputPath, `${svgContent}\n`, 'utf8');
  return outputPath;
}

function main() {
  const claims = JSON.parse(fs.readFileSync(CLAIMS_PATH, 'utf8'));
  const outputs = [
    {
      name: 'package-claims.svg',
      svg: renderChart(claims.packageClaims)
    },
    {
      name: 'ort-claims.svg',
      svg: renderChart(claims.ortClaims)
    }
  ];

  for (const output of outputs) {
    const outputPath = writeSvg(output.name, output.svg);
    process.stdout.write(`${path.relative(REPO_ROOT, outputPath)}\n`);
  }
}

main();
