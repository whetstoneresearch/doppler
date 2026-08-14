import { parseArgs } from 'util';
import { readdir } from 'node:fs/promises';

type ChainDetails = {
  name: string;
  explorerUrl: string;
  isTestnet: boolean;
}

const supportedChainIds: Record<number, true> = {
  1: true,
  143: true,
  4663: true,
  8453: true,
  42161: true,
  84532: true,
};

const supportedContractNames: Record<string, true> = {
  Airlock: true,
  AirlockMultisigTestnet: true,
  Bundler: true,
  DN404Factory: true,
  DopplerCreateXDeployer: true,
  DopplerDeployer: true,
  DopplerERC20V1: true,
  DopplerERC20V1Factory: true,
  DopplerHookInitializer: true,
  DopplerHookMigrator: true,
  DopplerLensQuoter: true,
  GovernanceFactory: true,
  LaunchpadGovernanceFactory: true,
  LockableUniswapV3Initializer: true,
  NoOpGovernanceFactory: true,
  NoOpMigrator: true,
  Quoter: true,
  RehypeDopplerHookInitializer: true,
  RehypeDopplerHookMigrator: true,
  StreamableFeesLockerV2: true,
  SwapRestrictorDopplerHook: true,
  TimelockFactory: true,
  TopUpDistributor: true,
  UniswapV2Locker: true,
  UniswapV2MigratorSplit: true,
  UniswapV4Initializer: true,
};

const chains: { [chainId: string]: ChainDetails } = {
  1: {
    name: 'Ethereum Mainnet',
    explorerUrl: 'https://etherscan.io',
    isTestnet: false,
  },
  143: {
    name: 'Monad Mainnet',
    explorerUrl: 'https://monadscan.com',
    isTestnet: false,
  },
  4663: {
    name: 'Robinhood Mainnet',
    explorerUrl: 'https://robinhoodchain.blockscout.com',
    isTestnet: false,
  },
  8453: {
    name: 'Base',
    explorerUrl: 'https://basescan.org',
    isTestnet: false,
  },
  42161: {
    name: 'Arbitrum One',
    explorerUrl: 'https://arbiscan.io',
    isTestnet: false,
  },
  84532: {
    name: 'Base Sepolia',
    explorerUrl: 'https://sepolia.basescan.org',
    isTestnet: true,
  },
};

type Transaction = {
  hash: null | `0x${string}`;
  contractName?: null | string;
  transactionType: 'CREATE' | 'CREATE2' | 'CALL';
  contractAddress: `0x${string}`;
  function?: null | string;
  arguments: string[];
  additionalContracts: {
    transactionType: 'CREATE' | 'CREATE2';
    contractName?: null | string;
    address: `0x${string}`;
  }[];
}

type Broadcast = {
  transactions: Transaction[];
  commit: string;
  chain: number;
  timestamp: number;
}

type Deployment = {
  contractName: string;
  contractAddress: `0x${string}`;
  hash: null | `0x${string}`;
  arguments: string[];
  commit: null | string;
  timestamp: number;
  source: 'broadcast' | 'manual';
};

type ManualDeployment = Omit<Deployment, 'source' | 'arguments'> & {
  arguments?: string[];
};

type ManualDeployments = {
  [chainId: string]: ManualDeployment[];
};

function shorten(a: string, length: number = 4): string {
  return `${a.slice(0, length + 2)}...${a.slice(-length)}`;
}

// Foundry changed the timestamp from s to ms so we need to handle both cases
function normalizeTimestamp(timestamp: number): number {
  return new Date(timestamp).getFullYear() === 1970 ? timestamp * 1000 : timestamp;
}

function convertTimestamp(timestamp: number): string {
  return new Date(normalizeTimestamp(timestamp)).toUTCString();
}

function generateTable(deployments: Deployment[], chainId: string): string {
  const explorerUrl = chains[chainId].explorerUrl;

  let content = `| Contract | Address | Transaction | Commit |\n`;
  content += '|---|---|---|---|\n';

  deployments.forEach((d) => {
    const transaction = d.hash
      ? `[${shorten(d.hash, 4)}](${explorerUrl}/tx/${d.hash})`
      : '—';
    const commit = d.commit
      ? `[${d.commit}](https://github.com/whetstoneresearch/doppler/commit/${d.commit})`
      : '—';

    content += `| ${d.contractName}`;
    content += ` | [${shorten(d.contractAddress)}](${explorerUrl}/address/${d.contractAddress})`;
    content += ` | ${transaction}`;
    content += ` | ${commit}`;
    content += ` | \n`;
  });

  return content;
}

function isPreferredDeployment(candidate: Deployment, current: Deployment): boolean {
  const candidateTimestamp = normalizeTimestamp(candidate.timestamp);
  const currentTimestamp = normalizeTimestamp(current.timestamp);

  if (candidateTimestamp !== currentTimestamp) {
    return candidateTimestamp > currentTimestamp;
  }

  if (candidate.source !== current.source) {
    return candidate.source === 'broadcast';
  }

  if (candidate.hash !== current.hash) {
    return candidate.hash !== null;
  }

  if (candidate.commit !== current.commit) {
    return candidate.commit !== null;
  }

  return false;
}

function getDeploymentIdentity(deployment: Deployment): string {
  return [
    deployment.contractName,
    deployment.contractAddress.toLowerCase(),
    normalizeTimestamp(deployment.timestamp),
  ].join(':');
}

function dedupeDeployments(deployments: Deployment[]): Deployment[] {
  const dedupedDeployments: { [key: string]: Deployment } = {};

  deployments.forEach((deployment) => {
    const key = getDeploymentIdentity(deployment);

    if (!dedupedDeployments[key] || isPreferredDeployment(deployment, dedupedDeployments[key])) {
      dedupedDeployments[key] = deployment;
    }
  });

  return Object.values(dedupedDeployments);
}

function sortDeploymentsByContractName(deployments: Deployment[]): Deployment[] {
  return [...deployments].sort((a, b) => a.contractName.localeCompare(b.contractName));
}

function getLatestDeployments(deployments: Deployment[]): Deployment[] {
  const latestDeployments: { [key: string]: Deployment } = {};

  deployments.forEach((deployment) => {
    if (!latestDeployments[deployment.contractName]) {
      latestDeployments[deployment.contractName] = deployment;
    } else if (isPreferredDeployment(deployment, latestDeployments[deployment.contractName])) {
      latestDeployments[deployment.contractName] = deployment;
    }
  });

  return Object.values(latestDeployments);
}

function isNonEmptyContractName(contractName: null | string | undefined): contractName is string {
  return typeof contractName === 'string' && contractName.length > 0;
}

function addDeployment(
  deployments: { [chainId: string]: Deployment[] },
  chainId: number | string,
  deployment: Deployment,
): void {
  const normalizedChainId = String(chainId);
  const numericChainId = Number(normalizedChainId);

  if (!Number.isSafeInteger(numericChainId)
    || numericChainId <= 0
    || normalizedChainId !== String(numericChainId)
  ) {
    throw new Error(`Invalid chain ID "${normalizedChainId}"`);
  }

  if (typeof deployment.contractName !== 'string' || deployment.contractName.length === 0) {
    throw new Error(`Invalid contract name for deployment on chain ID ${normalizedChainId}`);
  }

  if (supportedChainIds[numericChainId] !== true
    || supportedContractNames[deployment.contractName] !== true
  ) {
    return;
  }

  if (chains[numericChainId] === undefined) {
    throw new Error(`Missing chain metadata for chain ID ${normalizedChainId}`);
  }

  if (deployments[normalizedChainId] === undefined) {
    deployments[normalizedChainId] = [];
  }

  deployments[normalizedChainId].push(deployment);
}

async function loadManualDeployments(): Promise<ManualDeployments> {
  const manualPath = './deployments/manual.json';
  const manualFile = Bun.file(manualPath);

  if (!(await manualFile.exists())) {
    return {};
  }

  const manualDeployments = await manualFile.json() as ManualDeployments;

  for (const chainId in manualDeployments) {
    if (!Array.isArray(manualDeployments[chainId])) {
      throw new Error(`Expected deployments/manual.json chain ${chainId} to contain an array of deployments`);
    }
  }

  return manualDeployments;
}

async function generateHistoryLogs(): Promise<void> {
  // First let's find all the broadcast files generated by Foundry
  const broadcastFiles = await readdir('./broadcast', {
    recursive: true,
  });

  // Then we keep only the .json files and filter out the dry runs and multi broadcasts.
  // If a run only has a run-latest.json file, we still need to process it.
  const jsonFiles = broadcastFiles
    .filter((file) => file.endsWith('.json')
      && !file.includes('dry') && !file.startsWith('multi'))
    .filter((file) => {
      if (!file.includes('-latest')) return true;
      const scriptName = file.split('-latest')[0];
      return !broadcastFiles.some((f) => f.startsWith(scriptName) && !f.includes('-latest') && f.endsWith('.json'));
    });

  // Then we're going to iterate over each file to fetch the deployments
  const deployments: { [chainId: string]: Deployment[] } = {};

  for (const file of jsonFiles) {
    const filePath = `./broadcast/${file}`;
    const raw = Bun.file(filePath);
    const broadcast: Broadcast = await raw.json();

    for (const transaction of broadcast.transactions) {
      const transactionContractName = transaction.contractName;
      const transactionHash = transaction.hash;

      if ((transaction.transactionType === 'CREATE' || transaction.transactionType === 'CREATE2')
        && transactionHash !== null
        && isNonEmptyContractName(transactionContractName)
      ) {
        addDeployment(deployments, broadcast.chain, {
          contractName: transactionContractName,
          contractAddress: transaction.contractAddress,
          hash: transactionHash,
          arguments: transaction.arguments,
          commit: broadcast.commit,
          timestamp: broadcast.timestamp,
          source: 'broadcast',
        });
      }
    }

    // Also process additionalContracts from individual chain broadcasts
    for (const transaction of broadcast.transactions) {
      const transactionHash = transaction.hash;

      if (transaction.additionalContracts) {
        for (const additional of transaction.additionalContracts) {
          const additionalContractName = additional.contractName;

          if ((additional.transactionType === 'CREATE' || additional.transactionType === 'CREATE2')
            && isNonEmptyContractName(additionalContractName)
            && transactionHash !== null
          ) {
            addDeployment(deployments, broadcast.chain, {
              contractName: additionalContractName,
              contractAddress: additional.address,
              hash: transactionHash,
              arguments: [],
              commit: broadcast.commit,
              timestamp: broadcast.timestamp,
              source: 'broadcast',
            });
          }
        }
      }
    }
  }

  // Foundry now supports multichain broadcasts but these files must be handled differently
  const multiBroadcastFiles = await readdir('./broadcast/multi', {
    recursive: true,
  });

  // Filter to JSON files, excluding dry runs. For -latest dirs, only include if no timestamped version exists.
  const additionalJsonFiles = multiBroadcastFiles
    .filter((file) => file.endsWith('.json') && !file.includes('dry'))
    .filter((file) => {
      if (!file.includes('-latest')) return true;
      // Check if a timestamped version exists for this script
      const scriptName = file.split('-latest')[0];
      return !multiBroadcastFiles.some((f) => f.startsWith(scriptName) && !f.includes('-latest') && f.endsWith('.json'));
    });

  for (const file of additionalJsonFiles) {
    const filePath = `./broadcast/multi/${file}`;
    const raw = Bun.file(filePath);
    const multi: {
      deployments: Broadcast[];
    } = await raw.json();

    for (const broadcast of multi.deployments) {
      // Check if this broadcast has any contracts deployed via additionalContracts
      const hasAdditionalContracts = broadcast.transactions.some(tx =>
        tx.additionalContracts.some(ac =>
          (ac.transactionType === 'CREATE' || ac.transactionType === 'CREATE2')
          && isNonEmptyContractName(ac.contractName)
        )
      );

      for (const transaction of broadcast.transactions) {
        const transactionContractName = transaction.contractName;
        const transactionHash = transaction.hash;

        if ((
          transaction.transactionType === 'CREATE' || transaction.transactionType === 'CREATE2')
          && transactionHash !== null
          && isNonEmptyContractName(transactionContractName)
        ) {
          addDeployment(deployments, broadcast.chain, {
            contractName: transactionContractName,
            contractAddress: transaction.contractAddress,
            hash: transactionHash,
            arguments: transaction.arguments,
            commit: broadcast.commit,
            timestamp: broadcast.timestamp,
            source: 'broadcast',
          });
        }

        // A bit tricky but we also need to check if contracts were deployed as additional contracts
        for (const additional of transaction.additionalContracts) {
          const additionalContractName = additional.contractName;

          if ((additional.transactionType === 'CREATE' || additional.transactionType === 'CREATE2')
            && isNonEmptyContractName(additionalContractName)
            && transactionHash !== null
          ) {
            addDeployment(deployments, broadcast.chain, {
              contractName: additionalContractName,
              contractAddress: additional.address,
              hash: transactionHash,
              arguments: [],
              commit: broadcast.commit,
              timestamp: broadcast.timestamp,
              source: 'broadcast',
            });
          }
        }

        // Handle CREATE3 deployments recorded via StdConfig.set(string,address) calls
        // Only use this fallback if no contracts were deployed via additionalContracts
        // These have function "set(string,address)" and arguments [contractName, deployedAddress]
        if (!hasAdditionalContracts
          && transaction.transactionType === 'CALL'
          && transaction.function === 'set(string,address)'
          && transaction.arguments?.length === 2
          && transactionHash !== null
        ) {
          const [contractName, deployedAddress] = transaction.arguments;
          // Convert snake_case config name to PascalCase contract name (e.g., "airlock" -> "Airlock")
          const formattedName = contractName.split('_').map((s: string) => s.charAt(0).toUpperCase() + s.slice(1)).join('');

          addDeployment(deployments, broadcast.chain, {
            contractName: formattedName,
            contractAddress: deployedAddress as `0x${string}`,
            hash: transactionHash,
            arguments: [],
            commit: broadcast.commit,
            timestamp: broadcast.timestamp,
            source: 'broadcast',
          });
        }
      }
    }
  }

  const manualDeployments = await loadManualDeployments();

  for (const chainId in manualDeployments) {
    manualDeployments[chainId].forEach((deployment) => {
      addDeployment(deployments, chainId, {
        ...deployment,
        hash: deployment.hash ?? null,
        arguments: deployment.arguments ?? [],
        commit: deployment.commit ?? null,
        source: 'manual',
      });
    });
  }

  for (const chainId in deployments) {
    deployments[chainId] = dedupeDeployments(deployments[chainId]);
  }

  // Now we're going to generate the history logs for each chain
  for (const chainId in deployments) {
    if (deployments[chainId].length === 0) {
      continue;
    }

    let content = `# Deployments on ${chains[chainId].name} (${chainId})\n`;
    let timestamps: { [key: string]: Deployment[] } = {};

    deployments[chainId].forEach((d) => {
      const normalizedTimestamp = normalizeTimestamp(d.timestamp);

      if (!timestamps[normalizedTimestamp]) {
        timestamps[normalizedTimestamp] = [];
      }
      timestamps[normalizedTimestamp].push(d);
    });

    const sortedTimestamps = Object.keys(timestamps).sort((a, b) => Number(b) - Number(a));

    for (const timestamp of sortedTimestamps) {
      const t = timestamps[timestamp];
      content += `### ${convertTimestamp(Number(timestamp))}\n`;
      content += generateTable(t, chainId);
    }

    await Bun.write(`deployments/${chainId}.md`, content);
  }

  // Finally we generate the main Deployments.md file
  const mainnetLabels: string[] = [];
  let mainnetDeployments = '## Mainnet Deployments\n';

  for (const chainId in deployments) {
    if (deployments[chainId].length === 0 || chains[chainId].isTestnet) {
      continue;
    }

    const latestDeployments = sortDeploymentsByContractName(getLatestDeployments(deployments[chainId]));
    mainnetDeployments += `### ${chains[chainId].name} (${chainId})\n`;
    mainnetDeployments += generateTable(latestDeployments, chainId);
    mainnetLabels.push(chains[chainId].name);
  }

  const testnetLabels: string[] = [];
  let testnetDeployments = '## Testnet Deployments\n';

  for (const chainId in deployments) {
    if (deployments[chainId].length === 0 || !chains[chainId].isTestnet) {
      continue;
    }

    const latestDeployments = sortDeploymentsByContractName(getLatestDeployments(deployments[chainId]));
    testnetDeployments += `### ${chains[chainId].name} (${chainId})\n`;
    testnetDeployments += generateTable(latestDeployments, chainId);
    testnetLabels.push(chains[chainId].name);
  }

  await Bun.write(`./Deployments.md`, generateDeploymentsFile(mainnetLabels, mainnetDeployments, testnetLabels, testnetDeployments));

  // Generate JSON file for SDK consumption
  const addressesJson: { [chainId: string]: { [contractName: string]: string } } = {};

  for (const chainId in deployments) {
    if (deployments[chainId].length === 0) {
      continue;
    }

    const latestDeployments = sortDeploymentsByContractName(getLatestDeployments(deployments[chainId]));
    addressesJson[chainId] = {};

    latestDeployments.forEach((deployment) => {
      addressesJson[chainId][deployment.contractName] = deployment.contractAddress;
    });
  }

  await Bun.write(`./Deployments.json`, JSON.stringify(addressesJson, null, 2));
}

function generateDeploymentsFile(mainnetLabels: string[], mainnets: string, testnetLabels: string[], testnets: string): string {
  return `---
icon: pen-field
---

# Contract Addresses

Here are the networks that Doppler is officially deployed to:

- Mainnets: ${mainnetLabels.join(', ')}
- Testnets: ${testnetLabels.join(', ')}

{% hint style="danger" %}
If there are contracts not reflected here but claiming to be instances of Doppler, they are not considered canonical. Use with caution. :rotating_light:
{% endhint %}\n
${mainnets}
${testnets}
`;
}

async function main() {
  const { values } = parseArgs({
    args: Bun.argv,
    options: {
      output: {
        type: 'string',
      },
    },
    strict: true,
    allowPositionals: true,
  });

  switch (values.output) {
    case 'history':
      await generateHistoryLogs();
      break;
    default:
      console.error(`Unknown command: ${values.output}`);
      process.exit(1);
  }
}

main().catch((error) => {
  console.error('Fatal error:', error);
  process.exit(1);
});
