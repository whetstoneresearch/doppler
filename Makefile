include .env

export

# Install

install:
	forge install

# Test

test:
	forge test --show-progress

coverage:
	forge coverage --ir-minimum --report lcov

fuzz:
	forge test --mt invariant_ --show-progress

deep-fuzz:
	FOUNDRY_PROFILE=deep forge test --mt invariant_ --show-progress

# Logs

output-json:
	@bun run ./deployments/cli.ts --output json --chainId $(CHAIN_ID) --script $(SCRIPT)

output-markdown:
	@bun run ./deployments/cli.ts --output markdown --chainId $(CHAIN_ID)

output-docs:
	@bun run ./deployments/cli.ts --output docs

output-all:
	@bun run ./deployments/cli.ts --output json --chainId $(CHAIN_ID) --script $(SCRIPT)
	@bun run ./deployments/cli.ts --output markdown --chainId $(CHAIN_ID)
	@bun run ./deployments/cli.ts --output

# Mainnet protocol deployments

deploy-base:
	@forge script ./script/deploy/DeployBase.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) output-all CHAIN_ID=8453 SCRIPT=DeployBase

deploy-unichain:
	@forge script ./script/deploy/DeployUnichain.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_MAINNET_RPC_URL) --verify --etherscan-api-key ${UNISCAN_API_KEY} --broadcast --slow
	$(MAKE) output-all CHAIN_ID=130 SCRIPT=DeployUnichain

# Mainnet V4 deployments

deploy-v4-base:
	@forge script ./script/deployV4/DeployV4Base.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_MAINNET_RPC_URL) --verify --verifier blockscout --verifier-url $(BASE_MAINNET_VERIFIER_URL) --broadcast --slow
	$(MAKE) output-all CHAIN_ID=8453 SCRIPT=DeployV4Base

deploy-v4-unichain:
	@forge script ./script/deployV4/DeployV4Unichain.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_MAINNET_RPC_URL) --verify --verifier blockscout --verifier-url $(UNICHAIN_MAINNET_VERIFIER_URL) --broadcast --slow	
	$(MAKE) output-all CHAIN_ID=130 SCRIPT=DeployV4Unichain

deploy-v4-ink:
	@forge script ./script/deployV4/DeployV4Ink.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(INK_MAINNET_RPC_URL) --broadcast --slow --verify --verifier blockscout --verifier-url $(INK_MAINNET_VERIFIER_URL)
	$(MAKE) output-all CHAIN_ID=57073 SCRIPT=DeployV4Ink

# Testnet protocol deployments

deploy-base-sepolia:
	@forge script ./script/deploy/DeployBaseSepolia.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(BASE_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${BASESCAN_API_KEY} --broadcast --slow
	$(MAKE) output-all CHAIN_ID=84532 SCRIPT=DeployBaseSepolia

deploy-unichain-sepolia:
	@forge script ./script/deploy/DeployUnichainSepolia.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${UNISCAN_API_KEY} --broadcast --slow
	$(MAKE) output-all CHAIN_ID=1301 SCRIPT=DeployUnichainSepolia		
