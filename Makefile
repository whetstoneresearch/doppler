include .env

export

foo:
	@echo "Hello $(FOUNDRY_PROFILE)"

deploy-unichain-sepolia:
	@forge script ./script/deploy/DeployUnichainSepolia.s.sol --private-key $(PRIVATE_KEY) --rpc-url $(UNICHAIN_SEPOLIA_RPC_URL) --verify --etherscan-api-key ${UNISCAN_API_KEY} --broadcast --slow