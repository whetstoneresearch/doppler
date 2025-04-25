# Doppler

[![Test](https://github.com/whetstoneresearch/doppler/actions/workflows/test.yml/badge.svg)](https://github.com/whetstoneresearch/doppler/actions/workflows/test.yml)

This reposity contains the [Doppler](docs/Doppler.md) Protocol along with the [Airlock](/docs/Airlock.md) contracts.

## Usage

### Installation

First, you will need to install [Foundry](https://book.getfoundry.sh/getting-started/installation) if you don't already have it. Then, run the following commands:

```shell
# Clone the repository
$ git clone git@github.com:whetstoneresearch/doppler.git

# Install the dependencies
$ forge install
```

### Test

```shell
# Create a .env file for the configuration, don't forget to add an RPC endpoint for Mainnet
$ cp .env.example .env

# Then run the tests
$ forge test
```

Tests can be tweaked from the `.env` file, this is a nice way to try different testing scenarios without recompiling the contracts:

```shell
IS_TOKEN_0=FALSE
USING_ETH=FALSE
FEE=30
```

### Deploy

First be sure to set the `PROTOCOL_OWNER` variable in your .env file. V1 contracts running on Uniswap V3 can be deployed using the following command:

```shell
# --rpc-url is the chain you want to deploy to
# --private-key is the deployer wallet (not the owner)
forge script ./script/V1DeploymentScript.s.sol --rpc-url https://... --private-key 0x... --broadcast
```

```shell
# First load the environment variables
source .env

# Then use any of the following commands to deploy the contracts on the desired network

# Ink Mainnet
forge script ./script/DeployMainnet.s.sol --private-key $PRIVATE_KEY --rpc-url $INK_MAINNET_RPC_URL --verify --verifier blockscout --verifier-url $INK_MAINNET_VERIFIER_URL --broadcast --slow

# Base Mainnet
forge script ./script/DeployMainnet.s.sol --private-key $PRIVATE_KEY --rpc-url $BASE_MAINNET_RPC_URL --verify --verifier blockscout --verifier-url $BASE_MAINNET_VERIFIER_URL --broadcast --slow

# Unichain Sepolia
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $UNICHAIN_SEPOLIA_RPC_URL --verify --verifier blockscout --verifier-url $UNICHAIN_SEPOLIA_VERIFIER_URL --broadcast --slow

# Base Sepolia
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $BASE_SEPOLIA_RPC_URL --verify --verifier blockscout --verifier-url $BASE_SEPOLIA_VERIFIER_URL --broadcast --slow

# World Sepolia
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $WORLD_SEPOLIA_RPC_URL --verify --verifier blockscout --verifier-url $WORLD_SEPOLIA_VERIFIER_URL --broadcast --slow

# Ink Sepolia
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $INK_SEPOLIA_RPC_URL --verify --verifier blockscout --verifier-url $INK_SEPOLIA_VERIFIER_URL --broadcast --slow

# Arbitrum Sepolia
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --verify --verifier blockscout --verifier-url $ARBITRUM_SEPOLIA_VERIFIER_URL --broadcast --slow

# Monad Testnet
forge script ./script/DeployTestnet.s.sol --private-key $PRIVATE_KEY --rpc-url $MONAD_TESTNET_RPC_URL --verify --verifier sourcify --verifier-url $MONAD_TESTNET_VERIFIER_URL --broadcast --slow
```
