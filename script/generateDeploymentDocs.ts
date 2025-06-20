import { parseArgs } from 'util';

import { Deployment, Tracker } from './generateDeploymentLogs';

type ChainDetails = {
  name: string;
  explorerUrl: string;
}

const chains: {[chainId: string]: ChainDetails } = {
  '8453': {
    name: 'Base',
    explorerUrl: 'https://basescan.org',
  },
  '84532': {
    name: 'Base Sepolia',
    explorerUrl: 'https://sepolia.basescan.org',
  },
  '130': {
    name: 'Unichain',
    explorerUrl: 'https://uniscan.xyz',
  },
  '1301': {
    name: 'Unichain Sepolia',
    explorerUrl: 'https://sepolia.uniscan.xyz/',
  },
  '57073': {
    name: 'Ink',
    explorerUrl: 'https://explorer.inkonchain.com/',
  },
  '763373': {
    name: 'Ink Sepolia',
    explorerUrl: 'https://explorer-sepolia.inkonchain.com/',
  },
};

function shorten(a: string, length: number = 4): string {
  return `${a.slice(0, length + 2)}...${a.slice(-length)}`;
}

(async () => {
  const { values } = parseArgs({
    args: Bun.argv,
    options: {
      chainId: {
        type: 'string',
      },
    },
    strict: true,
    allowPositionals: true,
  });

  // Let's open the deployments tracker for the specified chain
  const file = Bun.file(`deployments/${values.chainId}.json`);
  const tracker = await file.json() as Tracker;
  
  let content = `# Deployments on ${chains[values.chainId].name} (${values.chainId})\n`;


  // We start by making a nice table for the latest deployments
  content += `## Latest deployments\n`;
  content += `| Contract | Address | Transaction | Commit |\n`;
  content += '|---|---|---|---|\n';

  const names: {[key: string]: Deployment} = {};

  tracker.deployments.forEach((deployment) => {
    if (!names[deployment.contractName]) {
      names[deployment.contractName] = deployment;
    } else {
      if (names[deployment.contractName].timestamp < deployment.timestamp) {
        names[deployment.contractName] = deployment;
      }
    }
  });

  Object.values(names).forEach((d) => {
      content += `| ${d.contractName}`;
      content += ` | [${shorten(d.contractAddress)}](${chains[values.chainId].explorerUrl}/address/${d.contractAddress})`;
      content += ` | [${shorten(d.hash, 4)}](${chains[values.chainId].explorerUrl}/tx/${d.hash})`;
      content += ` | [${d.commit.slice(0, 8)}](https://github.com/whetstoneresearch/doppler/commit/${d.commit})`;
      content += ` | \n`;  
  });

  // Then we're making a list of historical deployments
  content += `## History\n`;

  let timestamps: {[key: number]: Deployment[]} = {};

  tracker.deployments.forEach((d) => {
    if (!timestamps[d.timestamp]) {
      timestamps[d.timestamp] = [];
    }
    timestamps[d.timestamp].push(d);
  });

  for (let i = Object.values(timestamps).length - 1; i >= 0; i--) {
    const t = Object.values(timestamps)[i];

    content += `### ${new Date(t[0].timestamp).toUTCString()}\n`;
    content += `| Contract | Address | Transaction | Commit |\n`;
    content += '|---|---|---|---|\n';
  
    t.forEach((d) => {
      content += `| ${d.contractName}`;
      content += ` | [${shorten(d.contractAddress)}](${chains[values.chainId].explorerUrl}/address/${d.contractAddress})`;
      content += ` | [${shorten(d.hash, 4)}](${chains[values.chainId].explorerUrl}/tx/${d.hash})`;
      content += ` | [${d.commit.slice(0, 8)}](https://github.com/whetstoneresearch/doppler/commit/${d.commit})`;
      content += ` | \n`;
    });
  }  

  // And we save the file!
  await Bun.write(
    `deployments/${values.chainId}.md`,
    content,
  );
})();