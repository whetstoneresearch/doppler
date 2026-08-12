const DEFAULT_CONFIG_PATH = 'deployments.config.toml';

function assignmentKey(line: string): string | undefined {
  const match = line.match(/^([A-Za-z0-9_-]+)\s*=\s*(?:"(?:[^"\\]|\\.)*"|true|false|-?\d+(?:\.\d+)?)\r?$/);
  return match?.[1];
}

export function sortDeploymentConfig(input: string): string {
  const lines = input.split('\n');

  for (let start = 0; start < lines.length;) {
    if (assignmentKey(lines[start]) === undefined) {
      start += 1;
      continue;
    }

    let end = start + 1;
    while (end < lines.length && assignmentKey(lines[end]) !== undefined) {
      end += 1;
    }

    const sorted = lines.slice(start, end).sort((a, b) => {
      const aKey = assignmentKey(a)!;
      const bKey = assignmentKey(b)!;
      return aKey < bKey ? -1 : aKey > bKey ? 1 : 0;
    });
    lines.splice(start, end - start, ...sorted);
    start = end;
  }

  return lines.join('\n');
}

async function main(): Promise<void> {
  const args = Bun.argv.slice(2);
  if (args.length > 1) {
    throw new Error('Usage: bun scripts/sort-deployments-config.ts [path]');
  }

  const configPath = args[0] ?? DEFAULT_CONFIG_PATH;
  const configFile = Bun.file(configPath);
  if (!await configFile.exists()) {
    throw new Error(`Deployment config not found: ${configPath}`);
  }

  const original = await configFile.text();
  const sorted = sortDeploymentConfig(original);
  if (sorted === original) {
    return;
  }

  await Bun.write(configPath, sorted);
  console.log(`Sorted deployment config: ${configPath}`);
}

if (import.meta.main) {
  await main();
}
