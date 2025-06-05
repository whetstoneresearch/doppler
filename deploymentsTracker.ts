import { parseArgs } from 'util';

type Deployment = {
  contractName: string;
  contractAddress: `0x${string}`;
  hash: `0x${string}`;
  arguments: `0x${string}`[];
};

type Deployments = {
  deployments: Deployment[];
  commit: `0x${string}`;
  timestamp: number;
};

type Tracker = {
  chainId: string;
  history: Deployments[];
};

(async () => {
  const { values } = parseArgs({
    args: Bun.argv,
    options: {
      chainId: {
        type: 'string',
      },
      script: {
        type: 'string',
      },
    },
    strict: true,
    allowPositionals: true,
  });

  const path = `broadcast/${values.script}.s.sol/${values.chainId}/run-latest.json`;
  const file = Bun.file(path);

  const broadcast = await file.json();
  const deployments: Deployment[] = broadcast.transactions.map((transactions: Deployment) => ({
    contractName: transactions.contractName,
    contractAddress: transactions.contractAddress,
    hash: transactions.hash,
    arguments: transactions.arguments,
  }));

  const tracker = Bun.file(`deployments/${values.chainId}.json`);
  let trackerContent: Tracker;

  if (await tracker.exists()) {
    trackerContent = await tracker.json();
    trackerContent.history.push({
      deployments,
      commit: broadcast.commit,
      timestamp: broadcast.timestamp,
    });
  } else {
    trackerContent = {
      chainId: values.chainId,
      history: [{
        deployments,
        commit: broadcast.commit,
        timestamp: broadcast.timestamp,
      }],
    };
  }

  await Bun.write(
    `deployments/${values.chainId}.json`,
    JSON.stringify(trackerContent, null, 2));
})();