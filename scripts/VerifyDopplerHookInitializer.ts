#!/usr/bin/env bun

import { chmod, mkdir } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { encodeAbiParameters, getAddress, type Address } from 'viem';

const CONTRACT_PATH = 'src/initializers/DopplerHookInitializer.sol';
const CONTRACT_NAME = 'DopplerHookInitializer';
const CONTRACT_IDENTIFIER = `${CONTRACT_PATH}:${CONTRACT_NAME}`;
const ARTIFACT_PATH = `out/${CONTRACT_NAME}.sol/${CONTRACT_NAME}.json`;
const CACHE_PATH = 'cache/solidity-files-cache.json';
const BUILD_INFO_DIRECTORY = 'out/build-info';
const DEFAULT_CHAIN_ID = 42161;
const POLL_INTERVAL_MS = 15_000;
const MAX_STATUS_POLLS = 40;

const SOLC_PLATFORM_BY_RUNTIME: Record<string, string> = {
  'darwin:arm64': 'macosx-amd64',
  'darwin:x64': 'macosx-amd64',
  'linux:x64': 'linux-amd64',
  'win32:x64': 'windows-amd64',
};

type JsonRecord = Record<string, any>;
type EtherscanResponse<T> = {
  status: string;
  message: string;
  result: T;
};

type SourceCodeResult = {
  ContractName: string;
  SourceCode: string;
};

type ContractCreationResult = {
  contractAddress: string;
  creationBytecode: string;
};

type SolcReleaseList = {
  builds: Array<{
    path: string;
    version: string;
    sha256: string;
  }>;
  releases: Record<string, string>;
};

function usage(): string {
  return [
    'Usage: bun scripts/VerifyDopplerHookInitializer.ts [chain-id] [--dry-run]',
    '',
    `chain-id defaults to ${DEFAULT_CHAIN_ID}.`,
    '--dry-run reconstructs and checks the exact creation bytecode without submitting.',
  ].join('\n');
}

function parseArguments(): { chainId: number; dryRun: boolean } {
  const args = Bun.argv.slice(2);
  if (args.includes('--help') || args.includes('-h')) {
    console.log(usage());
    process.exit(0);
  }

  const unknownFlags = args.filter((arg) => arg.startsWith('-') && arg !== '--dry-run');
  const positional = args.filter((arg) => !arg.startsWith('-'));
  if (unknownFlags.length > 0 || positional.length > 1) {
    throw new Error(usage());
  }

  const chainId = Number(positional[0] ?? DEFAULT_CHAIN_ID);
  if (!Number.isSafeInteger(chainId) || chainId <= 0) {
    throw new Error(`Invalid chain ID: ${positional[0]}\n\n${usage()}`);
  }

  return { chainId, dryRun: args.includes('--dry-run') };
}

function parseAddressConfig(config: string, chainId: number): Record<string, string> {
  const header = `[${chainId}.address]`;
  const lines = config.split(/\r?\n/);
  const start = lines.findIndex((line) => line.trim() === header);
  if (start === -1) {
    throw new Error(`Missing ${header} in deployments.config.toml`);
  }

  const addresses: Record<string, string> = {};
  for (let index = start + 1; index < lines.length; index++) {
    const line = lines[index].trim();
    if (line.startsWith('[')) break;

    const match = line.match(/^([A-Za-z0-9_]+)\s*=\s*"(0x[0-9A-Fa-f]{40})"$/);
    if (match) addresses[match[1]] = match[2];
  }
  return addresses;
}

function requireAddress(addresses: Record<string, string>, key: string, chainId: number): Address {
  const value = addresses[key];
  if (!value) {
    throw new Error(`Missing ${key} in [${chainId}.address]`);
  }
  return getAddress(value);
}

async function readJson(path: string): Promise<JsonRecord> {
  const file = Bun.file(path);
  if (!await file.exists()) {
    throw new Error(`Required file not found: ${path}`);
  }
  return file.json();
}

function collectBuildIds(value: unknown, buildIds = new Set<string>()): Set<string> {
  if (!value || typeof value !== 'object') return buildIds;
  if ('build_id' in value && typeof (value as JsonRecord).build_id === 'string') {
    buildIds.add((value as JsonRecord).build_id);
  }
  for (const child of Object.values(value)) collectBuildIds(child, buildIds);
  return buildIds;
}

function dependencyClosure(cacheFiles: JsonRecord): Set<string> {
  const dependencies = new Set<string>();
  const pending = [CONTRACT_PATH];

  while (pending.length > 0) {
    const sourcePath = pending.pop()!;
    if (dependencies.has(sourcePath)) continue;
    dependencies.add(sourcePath);

    const cacheEntry = cacheFiles[sourcePath];
    if (!cacheEntry) {
      throw new Error(`Missing compiler cache entry for ${sourcePath}`);
    }
    for (const importedPath of cacheEntry.imports ?? []) pending.push(importedPath);
  }

  return dependencies;
}

async function resolveSolc(compilerVersion: string): Promise<string> {
  const configuredPath = Bun.env.SOLC_PATH;
  if (configuredPath) return configuredPath;

  const platform = SOLC_PLATFORM_BY_RUNTIME[`${process.platform}:${process.arch}`];
  if (!platform) {
    throw new Error(`No automatic solc download for ${process.platform}/${process.arch}; set SOLC_PATH`);
  }

  const shortVersion = compilerVersion.split('+')[0];
  const releaseListUrl = `https://binaries.soliditylang.org/${platform}/list.json`;
  const releaseListResponse = await fetch(releaseListUrl);
  if (!releaseListResponse.ok) {
    throw new Error(`Could not retrieve ${releaseListUrl}: HTTP ${releaseListResponse.status}`);
  }
  const releaseList = await releaseListResponse.json() as SolcReleaseList;
  const releasePath = releaseList.releases[shortVersion];
  const build = releaseList.builds.find((candidate) => candidate.path === releasePath);
  if (!releasePath || !build) throw new Error(`No native solc release found for ${compilerVersion}`);

  const cacheDirectory = join(homedir(), '.cache', 'doppler', 'solc');
  const binaryPath = join(cacheDirectory, releasePath);
  const binaryFile = Bun.file(binaryPath);
  if (!await binaryFile.exists()) {
    const binaryResponse = await fetch(`${releaseListUrl.slice(0, -'list.json'.length)}${releasePath}`);
    if (!binaryResponse.ok) {
      throw new Error(`Could not download solc ${compilerVersion}: HTTP ${binaryResponse.status}`);
    }
    const binary = await binaryResponse.arrayBuffer();
    const digest = new Bun.CryptoHasher('sha256').update(binary).digest('hex');
    if (`0x${digest}` !== build.sha256) {
      throw new Error(`Checksum mismatch while downloading solc ${compilerVersion}`);
    }
    await mkdir(cacheDirectory, { recursive: true });
    await Bun.write(binaryPath, binary);
  }
  if (process.platform !== 'win32') await chmod(binaryPath, 0o755);
  return binaryPath;
}

async function compile(solcPath: string, input: JsonRecord): Promise<JsonRecord> {
  const compiler = Bun.spawn([solcPath, '--standard-json'], {
    stdin: 'pipe',
    stdout: 'pipe',
    stderr: 'pipe',
  });
  compiler.stdin.write(JSON.stringify(input));
  compiler.stdin.end();
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(compiler.stdout).text(),
    new Response(compiler.stderr).text(),
    compiler.exited,
  ]);
  if (exitCode !== 0) throw new Error(`solc exited ${exitCode}: ${stderr}`);

  const output = JSON.parse(stdout);
  const errors = (output.errors ?? []).filter((error: JsonRecord) => error.severity === 'error');
  if (errors.length > 0) {
    throw new Error(errors.map((error: JsonRecord) => error.formattedMessage ?? error.message).join('\n'));
  }
  return output;
}

function countAstIds(value: unknown): number {
  if (!value || typeof value !== 'object') return 0;
  let count = typeof (value as JsonRecord).id === 'number' ? 1 : 0;
  for (const child of Object.values(value)) count += countAstIds(child);
  return count;
}

function makeAstPadding(astIdCount: number, sourceIndex: number): string {
  if (astIdCount === 1) return '';
  if (astIdCount === 2) return 'pragma solidity >=0.0.0;';
  if (astIdCount === 3) return `enum P${sourceIndex}{A}`;
  if (astIdCount < 1) throw new Error(`Invalid AST ID count: ${astIdCount}`);

  // A file-level bool constant contributes three fixed AST IDs. Every unary ! adds
  // one more ID, allowing compact padding for an arbitrary original AST count.
  const declarationCount = Math.max(1, Math.ceil((astIdCount - 4) / 500));
  let remainingUnaryNodes = astIdCount - 1 - 3 * declarationCount;
  const declarations: string[] = [];

  for (let index = 0; index < declarationCount; index++) {
    const declarationsLeft = declarationCount - index;
    const unaryNodes = Math.ceil(remainingUnaryNodes / declarationsLeft);
    remainingUnaryNodes -= unaryNodes;
    declarations.push(`bool constant P${sourceIndex}_${index}=${'!'.repeat(unaryNodes)}true;`);
  }

  if (remainingUnaryNodes !== 0) {
    throw new Error(`Failed to construct AST padding for source ${sourceIndex}`);
  }
  return declarations.join('');
}

async function etherscanGet<T>(
  apiKey: string,
  chainId: number,
  parameters: Record<string, string>,
): Promise<EtherscanResponse<T>> {
  const url = new URL('https://api.etherscan.io/v2/api');
  url.search = new URLSearchParams({ chainid: String(chainId), apikey: apiKey, ...parameters }).toString();
  const response = await fetch(url);
  const body = await response.json() as EtherscanResponse<T>;
  if (!response.ok) throw new Error(`Etherscan HTTP ${response.status}: ${JSON.stringify(body)}`);
  return body;
}

async function submitVerification(
  apiKey: string,
  chainId: number,
  address: Address,
  compilerVersion: string,
  constructorArguments: string,
  input: JsonRecord,
): Promise<string> {
  const url = new URL('https://api.etherscan.io/v2/api');
  url.search = new URLSearchParams({
    chainid: String(chainId),
    apikey: apiKey,
    module: 'contract',
    action: 'verifysourcecode',
  }).toString();
  const body = new URLSearchParams({
    contractaddress: address,
    sourceCode: JSON.stringify(input),
    codeformat: 'solidity-standard-json-input',
    contractname: CONTRACT_IDENTIFIER,
    compilerversion: `v${compilerVersion}`,
    constructorArguments: constructorArguments.slice(2),
    licenseType: '14',
  });
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  const result = await response.json() as EtherscanResponse<string>;
  if (!response.ok || result.status !== '1') {
    throw new Error(`Verification submission failed: ${result.result}`);
  }
  return result.result;
}

async function waitForVerification(apiKey: string, chainId: number, guid: string): Promise<void> {
  for (let attempt = 0; attempt < MAX_STATUS_POLLS; attempt++) {
    if (attempt > 0) await Bun.sleep(POLL_INTERVAL_MS);
    const status = await etherscanGet<string>(apiKey, chainId, {
      module: 'contract',
      action: 'checkverifystatus',
      guid,
    });
    if (status.status === '1' || /already verified/i.test(status.result)) return;
    if (!/pending in queue/i.test(status.result)) {
      throw new Error(`Verification failed: ${status.result}`);
    }
    console.log('Verification pending...');
  }
  throw new Error(`Verification remained pending after ${MAX_STATUS_POLLS} checks`);
}

async function main(): Promise<void> {
  const { chainId, dryRun } = parseArguments();
  const apiKey = Bun.env.ETHERSCAN_API_KEY;
  if (!apiKey) throw new Error('ETHERSCAN_API_KEY is not set');

  const addresses = parseAddressConfig(await Bun.file('deployments.config.toml').text(), chainId);
  const address = requireAddress(addresses, 'doppler_hook_initializer', chainId);
  const airlock = requireAddress(addresses, 'airlock', chainId);
  const poolManager = requireAddress(addresses, 'uniswap_v4_pool_manager', chainId);
  const constructorArguments = encodeAbiParameters(
    [{ type: 'address' }, { type: 'address' }],
    [airlock, poolManager],
  );

  const sourceStatus = await etherscanGet<SourceCodeResult[]>(apiKey, chainId, {
    module: 'contract',
    action: 'getsourcecode',
    address,
  });
  const existingSource = sourceStatus.result[0];
  if (existingSource?.SourceCode && !dryRun) {
    console.log(`${CONTRACT_NAME} is already verified at ${address} on chain ${chainId}.`);
    return;
  }

  const creationStatus = await etherscanGet<ContractCreationResult[]>(apiKey, chainId, {
    module: 'contract',
    action: 'getcontractcreation',
    contractaddresses: address,
  });
  if (creationStatus.status !== '1' || !creationStatus.result[0]?.creationBytecode) {
    throw new Error(`Could not retrieve creation bytecode: ${JSON.stringify(creationStatus.result)}`);
  }
  const creationBytecode = creationStatus.result[0].creationBytecode.toLowerCase();

  const [artifact, cache] = await Promise.all([readJson(ARTIFACT_PATH), readJson(CACHE_PATH)]);
  const metadata = typeof artifact.metadata === 'string' ? JSON.parse(artifact.metadata) : artifact.metadata;
  const compilerVersion = metadata.compiler.version as string;
  const solcPath = await resolveSolc(compilerVersion);
  const versionProcess = Bun.spawn([solcPath, '--version'], { stdout: 'pipe', stderr: 'pipe' });
  const [versionOutput, versionError, versionExitCode] = await Promise.all([
    new Response(versionProcess.stdout).text(),
    new Response(versionProcess.stderr).text(),
    versionProcess.exited,
  ]);
  if (versionExitCode !== 0 || !versionOutput.includes(compilerVersion)) {
    throw new Error(
      `Compiler ${solcPath} does not provide ${compilerVersion}: ${versionError || versionOutput}`,
    );
  }

  const artifactCreationBytecode = `${artifact.bytecode.object}${constructorArguments.slice(2)}`.toLowerCase();
  if (artifactCreationBytecode !== creationBytecode) {
    throw new Error('The local artifact and constructor arguments do not match the explorer creation bytecode');
  }

  const cacheArtifacts = cache.files?.[CONTRACT_PATH]?.artifacts?.[CONTRACT_NAME];
  const buildIds = [...collectBuildIds(cacheArtifacts)];
  const requestedBuildId = Bun.env.DOPPLER_HOOK_BUILD_ID;
  const buildId = requestedBuildId ?? (buildIds.length === 1 ? buildIds[0] : undefined);
  if (!buildId) {
    throw new Error(
      `Could not select one build ID (${buildIds.join(', ') || 'none found'}). Set DOPPLER_HOOK_BUILD_ID explicitly.`,
    );
  }

  const buildInfo = await readJson(`${BUILD_INFO_DIRECTORY}/${buildId}.json`);
  const sourceEntries = Object.entries(buildInfo.source_id_to_path as Record<string, string>)
    .sort(([left], [right]) => Number(left) - Number(right));
  if (sourceEntries.length === 0) throw new Error(`Build ${buildId} does not contain source paths`);

  const fullSources: JsonRecord = {};
  for (const [, sourcePath] of sourceEntries) {
    const sourceFile = Bun.file(sourcePath);
    if (!await sourceFile.exists()) throw new Error(`Build source not found: ${sourcePath}`);
    fullSources[sourcePath] = { content: await sourceFile.text() };
  }

  const settings = structuredClone(metadata.settings) as JsonRecord;
  delete settings.compilationTarget;
  settings.outputSelection = { '*': { '': ['ast'] } };
  console.log(`Reconstructing AST layout from build ${buildId} (${sourceEntries.length} source units)...`);
  const astOutput = await compile(solcPath, { language: 'Solidity', sources: fullSources, settings });
  const dependencies = dependencyClosure(cache.files);

  const verificationSources: JsonRecord = {};
  for (let index = 0; index < sourceEntries.length; index++) {
    const sourcePath = sourceEntries[index][1];
    const sourceAst = astOutput.sources?.[sourcePath]?.ast;
    if (!sourceAst) throw new Error(`Compiler did not return an AST for ${sourcePath}`);
    verificationSources[sourcePath] = dependencies.has(sourcePath)
      ? fullSources[sourcePath]
      : { content: makeAstPadding(countAstIds(sourceAst), index) };
  }

  settings.outputSelection = {
    '*': {
      [CONTRACT_NAME]: ['abi', 'evm.bytecode.object', 'evm.deployedBytecode.object', 'metadata'],
    },
  };
  const verificationInput = { language: 'Solidity', sources: verificationSources, settings };
  console.log(`Compiling ${CONTRACT_IDENTIFIER} with the original AST numbering...`);
  const verificationOutput = await compile(solcPath, verificationInput);
  const compiledBytecode = verificationOutput.contracts?.[CONTRACT_PATH]?.[CONTRACT_NAME]?.evm?.bytecode?.object;
  if (!compiledBytecode) throw new Error(`Compiler did not emit bytecode for ${CONTRACT_IDENTIFIER}`);

  const reconstructedCreationBytecode = `0x${compiledBytecode}${constructorArguments.slice(2)}`.toLowerCase();
  if (reconstructedCreationBytecode !== creationBytecode) {
    throw new Error('Reconstructed verification bytecode does not match the explorer creation bytecode');
  }
  console.log(`Exact creation bytecode match (${compiledBytecode.length / 2} compiler bytes).`);

  if (dryRun) {
    console.log('Dry run complete; verification was not submitted.');
    return;
  }

  const guid = await submitVerification(
    apiKey,
    chainId,
    address,
    compilerVersion,
    constructorArguments,
    verificationInput,
  );
  console.log(`Submitted Etherscan verification ${guid}.`);
  await waitForVerification(apiKey, chainId, guid);

  const verified = await etherscanGet<SourceCodeResult[]>(apiKey, chainId, {
    module: 'contract',
    action: 'getsourcecode',
    address,
  });
  if (verified.result[0]?.ContractName !== CONTRACT_NAME || !verified.result[0]?.SourceCode) {
    throw new Error('Explorer accepted the job but did not return verified source code');
  }
  console.log(`Verified ${CONTRACT_NAME} at ${address} on chain ${chainId}.`);
}

if (import.meta.main) {
  await main();
}
