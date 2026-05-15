export {};

type Snapshot = Record<string, string>;

type Metric =
  | 'Airlock.create'
  | 'Airlock.migrate'
  | 'initializerBuy'
  | 'initializerSell'
  | 'migratorBuy'
  | 'migratorSell';

type ParsedKey = {
  key: string;
  launch: string;
  initializer: string;
  migrator: string;
  governance: string;
  balanceLimit: string;
  proceedsSplit: string;
  metric: Metric;
};

type Change = ParsedKey & {
  base: bigint;
  head: bigint;
  delta: bigint;
  percent: number;
  section: string;
  facets: string[];
};

type CliOptions = {
  basePath: string;
  headPath: string;
  outPath?: string;
};

const MARKER = '<!-- doppler-gas-benchmark-report -->';
const ABSOLUTE_THRESHOLD = 500n;
const PERCENT_THRESHOLD = 0.005;
const TOP_LIMIT = 5;

const KEY_PATTERN = /^(Static|Dynamic|Multicurve)_(LockableUniswapV3Initializer|UniswapV4Initializer|DopplerHookInitializer)_(NoOpMigrator|UniswapV2MigratorSplit|DopplerHookMigrator)_(NoOpGovernanceFactory|LaunchpadGovernanceFactory|GovernanceFactory)_(BalanceLimitDisabled|BalanceLimitExempt|BalanceLimitApplied)_(ProceedsSplitDisabled|ProceedsSplitEnabled)\/(Airlock\.create|Airlock\.migrate|initializerBuy|initializerSell|migratorBuy|migratorSell)$/;

function parseArgs(args: string[]): CliOptions {
  const options: CliOptions = {basePath: '', headPath: ''};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    if (arg === '--base' && next) {
      options.basePath = next;
      i++;
    } else if (arg === '--head' && next) {
      options.headPath = next;
      i++;
    } else if (arg === '--out' && next) {
      options.outPath = next;
      i++;
    } else {
      throw new Error(`Unknown or incomplete argument: ${arg}`);
    }
  }

  if (!options.basePath || !options.headPath) {
    throw new Error('Usage: bun scripts/gas-benchmark-report.ts --base <base.json> --head <head.json> [--out <report.md>]');
  }

  return options;
}

async function readSnapshot(path: string): Promise<Snapshot> {
  const data = await Bun.file(path).json();

  if (!data || typeof data !== 'object' || Array.isArray(data)) {
    throw new Error(`${path} must be a JSON object`);
  }

  const snapshot: Snapshot = {};
  const invalidKeys: string[] = [];

  for (const [key, value] of Object.entries(data)) {
    if (!parseKey(key)) {
      invalidKeys.push(key);
    }

    if (typeof value !== 'string') {
      throw new Error(`${path} has invalid gas value for ${key}: ${String(value)}`);
    }

    parseGas(value, key, path);
    snapshot[key] = value;
  }

  if (invalidKeys.length > 0) {
    throw new Error(invalidKeyMessage(path, invalidKeys));
  }

  return snapshot;
}

function parseKey(key: string): ParsedKey | undefined {
  const match = key.match(KEY_PATTERN);

  if (!match) return undefined;

  return {
    key,
    launch: match[1],
    initializer: match[2],
    migrator: match[3],
    governance: match[4],
    balanceLimit: match[5],
    proceedsSplit: match[6],
    metric: match[7] as Metric,
  };
}

function parseGas(value: string, key: string, source: string): bigint {
  if (!/^\d+$/.test(value)) {
    throw new Error(`${source} has invalid gas value for ${key}: ${value}`);
  }

  return BigInt(value);
}

function invalidKeyMessage(source: string, keys: string[]): string {
  const visibleKeys = keys.slice(0, TOP_LIMIT).map((key) => `- ${key}`);
  const hiddenCount = keys.length - visibleKeys.length;

  if (hiddenCount > 0) {
    visibleKeys.push(`- ${hiddenCount} more hidden.`);
  }

  return `${source} has invalid benchmark key(s):\n${visibleKeys.join('\n')}`;
}

function metricSection(metric: Metric): string {
  if (metric === 'Airlock.create') return 'Creation costs';
  if (metric === 'Airlock.migrate') return 'Migration costs';
  if (metric === 'initializerBuy' || metric === 'initializerSell') return 'Pre-migration swaps';
  return 'Post-migration swaps';
}

function metricLabel(metric: Metric): string {
  const labels: Record<Metric, string> = {
    'Airlock.create': 'create',
    'Airlock.migrate': 'migrate',
    initializerBuy: 'initializer buy',
    initializerSell: 'initializer sell',
    migratorBuy: 'migrator buy',
    migratorSell: 'migrator sell',
  };

  return labels[metric];
}

function pretty(value: string): string {
  return value
    .replace(/(V\d)([A-Z])/g, '$1 $2')
    .replace(/([a-z])([A-Z])/g, '$1 $2')
    .replace('No Op', 'No-op')
    .replace('Balance Limit', 'Balance limit')
    .replace('Proceeds Split', 'Proceeds split');
}

function formatGas(value: bigint): string {
  return value.toLocaleString('en-US');
}

function formatDelta(value: bigint): string {
  const sign = value > 0n ? '+' : '';
  return `${sign}${formatGas(value)}`;
}

function formatPercent(value: number): string {
  const sign = value > 0 ? '+' : '';
  return `${sign}${(value * 100).toFixed(2)}%`;
}

function isSignificant(change: Change): boolean {
  const absolute = change.delta < 0n ? -change.delta : change.delta;

  return absolute >= ABSOLUTE_THRESHOLD || Math.abs(change.percent) >= PERCENT_THRESHOLD;
}

function describeFacets(change: ParsedKey): string[] {
  const facets = [pretty(change.launch), pretty(change.initializer), pretty(change.migrator), pretty(change.governance)];

  if (change.balanceLimit !== 'BalanceLimitDisabled') {
    facets.push(pretty(change.balanceLimit));
  }

  if (change.proceedsSplit !== 'ProceedsSplitDisabled') {
    facets.push(pretty(change.proceedsSplit));
  }

  return facets;
}

function compareSnapshots(base: Snapshot, head: Snapshot): {changes: Change[]; newKeys: string[]; removedKeys: string[]; invalidKeys: string[]} {
  const baseKeys = new Set(Object.keys(base));
  const headKeys = new Set(Object.keys(head));
  const sharedKeys = [...headKeys].filter((key) => baseKeys.has(key)).sort();
  const newKeys = [...headKeys].filter((key) => !baseKeys.has(key)).sort();
  const removedKeys = [...baseKeys].filter((key) => !headKeys.has(key)).sort();
  const invalidKeys: string[] = [];
  const changes: Change[] = [];

  for (const key of sharedKeys) {
    const parsed = parseKey(key);

    if (!parsed) {
      invalidKeys.push(key);
      continue;
    }

    const baseGas = parseGas(base[key], key, 'base snapshot');
    const headGas = parseGas(head[key], key, 'head snapshot');
    const delta = headGas - baseGas;

    if (delta === 0n) continue;

    changes.push({
      ...parsed,
      base: baseGas,
      head: headGas,
      delta,
      percent: Number(delta) / Number(baseGas),
      section: metricSection(parsed.metric),
      facets: describeFacets(parsed),
    });
  }

  return {changes, newKeys, removedKeys, invalidKeys};
}

function sortByMagnitude(changes: Change[]): Change[] {
  return [...changes].sort((a, b) => {
    const absoluteA = a.delta < 0n ? -a.delta : a.delta;
    const absoluteB = b.delta < 0n ? -b.delta : b.delta;

    if (absoluteA === absoluteB) return a.key.localeCompare(b.key);
    return absoluteA > absoluteB ? -1 : 1;
  });
}

function summarizeByFacet(changes: Change[]): Array<{facet: string; regressions: number; improvements: number; net: bigint}> {
  const rollup = new Map<string, {regressions: number; improvements: number; net: bigint}>();

  for (const change of changes) {
    const facets = [change.section, pretty(change.balanceLimit), pretty(change.proceedsSplit)];

    for (const facet of facets) {
      const current = rollup.get(facet) ?? {regressions: 0, improvements: 0, net: 0n};
      current.net += change.delta;

      if (change.delta > 0n) current.regressions++;
      if (change.delta < 0n) current.improvements++;

      rollup.set(facet, current);
    }
  }

  return [...rollup.entries()]
    .map(([facet, summary]) => ({facet, ...summary}))
    .sort((a, b) => {
      const absoluteA = a.net < 0n ? -a.net : a.net;
      const absoluteB = b.net < 0n ? -b.net : b.net;

      if (absoluteA === absoluteB) return a.facet.localeCompare(b.facet);
      return absoluteA > absoluteB ? -1 : 1;
    });
}

function row(change: Change): string {
  return `| ${metricLabel(change.metric)} | ${change.facets.join(', ')} | ${formatGas(change.base)} | ${formatGas(change.head)} | ${formatDelta(change.delta)} | ${formatPercent(change.percent)} |`;
}

function table(title: string, changes: Change[]): string[] {
  if (changes.length === 0) return [];

  const lines = [`### ${title}`, '| Metric | Facets | Base | Head | Delta | Delta % |', '|---|---|---:|---:|---:|---:|'];
  lines.push(...changes.slice(0, TOP_LIMIT).map(row));

  if (changes.length > TOP_LIMIT) {
    lines.push(`\n_${changes.length - TOP_LIMIT} more significant change(s) hidden below._`);
  }

  return lines;
}

function keyList(title: string, keys: string[]): string[] {
  if (keys.length === 0) return [];

  return [`### ${title}`, ...keys.slice(0, TOP_LIMIT).map((key) => `- \`${key}\``), ...(keys.length > TOP_LIMIT ? [`- _${keys.length - TOP_LIMIT} more hidden._`] : [])];
}

function buildReport(base: Snapshot, head: Snapshot): string {
  const {changes, newKeys, removedKeys, invalidKeys} = compareSnapshots(base, head);
  const significant = sortByMagnitude(changes.filter(isSignificant));
  const regressions = significant.filter((change) => change.delta > 0n);
  const improvements = significant.filter((change) => change.delta < 0n);
  const noise = changes.length - significant.length;
  const net = significant.reduce((total, change) => total + change.delta, 0n);
  const largestRegression = regressions[0];
  const largestImprovement = improvements[0];
  const lines = [MARKER, '## Gas Benchmark Summary', ''];

  if (significant.length === 0 && newKeys.length === 0 && removedKeys.length === 0) {
    lines.push('No significant gas benchmark changes were found in `snapshots/GasBenchmark.json`.');
  } else {
    lines.push(`Status: ${regressions.length} regression(s), ${improvements.length} improvement(s), ${noise} below-threshold change(s).`);
    lines.push(`Net significant delta: ${formatDelta(net)} gas.`);

    if (largestRegression) {
      lines.push(`Largest regression: ${metricLabel(largestRegression.metric)} with ${largestRegression.facets.join(', ')} ${formatDelta(largestRegression.delta)} gas (${formatPercent(largestRegression.percent)}).`);
    }

    if (largestImprovement) {
      lines.push(`Largest improvement: ${metricLabel(largestImprovement.metric)} with ${largestImprovement.facets.join(', ')} ${formatDelta(largestImprovement.delta)} gas (${formatPercent(largestImprovement.percent)}).`);
    }
  }

  const facetSummary = summarizeByFacet(significant).slice(0, 8);
  if (facetSummary.length > 0) {
    lines.push('', '### Changed Facets', '| Facet | Regressions | Improvements | Net Delta |', '|---|---:|---:|---:|');
    lines.push(...facetSummary.map((summary) => `| ${summary.facet} | ${summary.regressions} | ${summary.improvements} | ${formatDelta(summary.net)} |`));
  }

  lines.push('', ...table('Top Regressions', regressions), '', ...table('Top Improvements', improvements));

  const bySection = new Map<string, Change[]>();
  for (const change of significant) {
    const sectionChanges = bySection.get(change.section) ?? [];
    sectionChanges.push(change);
    bySection.set(change.section, sectionChanges);
  }

  if (bySection.size > 0) {
    lines.push('', '<details>', '<summary>All significant changes by section</summary>', '');

    for (const [section, sectionChanges] of [...bySection.entries()].sort(([a], [b]) => a.localeCompare(b))) {
      lines.push(`#### ${section}`, '| Metric | Facets | Base | Head | Delta | Delta % |', '|---|---|---:|---:|---:|---:|');
      lines.push(...sortByMagnitude(sectionChanges).map(row), '');
    }

    lines.push('</details>');
  }

  const structureNotes = [...keyList('New Benchmark Keys', newKeys), '', ...keyList('Removed Benchmark Keys', removedKeys)].filter(Boolean);
  if (structureNotes.length > 0) {
    lines.push('', ...structureNotes);
  }

  if (invalidKeys.length > 0) {
    lines.push('', '### Unparsed Keys', ...invalidKeys.slice(0, TOP_LIMIT).map((key) => `- \`${key}\``));
  }

  return `${lines.join('\n').replace(/\n{3,}/g, '\n\n')}\n`;
}

async function main() {
  const options = parseArgs(Bun.argv.slice(2));
  const [base, head] = await Promise.all([readSnapshot(options.basePath), readSnapshot(options.headPath)]);
  const report = buildReport(base, head);

  if (options.outPath) {
    await Bun.write(options.outPath, report);
  } else {
    process.stdout.write(report);
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
