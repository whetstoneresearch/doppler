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

Deploying can take different forms depending on what one wants to do, the three main cases being:

- Deploying the whole protocol, for example on a testnet or on a new production chain
- Deploying a new _periphery_ contract, (e.g. `Bundler`)
- Deploying a new module, (e.g. `UniswapV4Initializer`)

In most cases, dedicated scripts are provided in the `script` folder and all require some base set up:

```shell
# If you haven't done it yet, create your own .env file by copying the given example
$ cp .env.example .env
```

Then using your favorite editor, edit the `.env` file and set the following variables:

```shell
# Private key of the wallet used to deploy the contracts
PRIVATE_KEY=0x...


```

#### Deploying the whole protocol

See `Deploy.s.sol`.

#### Deploying a new periphery contract

Deploying a new periphery contract should be as simple as running its script. For example,

#### Deploying a new module

Deploying a new module is slightly different than deploying a periphery contract, as an extra step is required: the module must be registered in the `Airlock` contract. This is done by calling the `setModuleState` function of the `Airlock` contract and passing the address of the new module along its type (`TokenFactory` or `PoolInitializer` for example).
In our case, the protocol multisig being the admin of the `Airlock`, the transaction must be executed via the Safe interface.

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
