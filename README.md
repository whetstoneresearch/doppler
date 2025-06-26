# Doppler

[![Test](https://github.com/whetstoneresearch/doppler/actions/workflows/test.yml/badge.svg)](https://github.com/whetstoneresearch/doppler/actions/workflows/test.yml)

This reposity contains the [Doppler](docs/Doppler.md) Protocol along with the [Airlock](/docs/Airlock.md) contracts You can learn more about the technical aspects in the [documentation](https://docs.doppler.lol).

## Deployments

Deployments are listed in the [Deployments](https://docs.doppler.lol/resources/contract-addresses) section of the documentation.

## Usage

### Installation

First, you will need to install [Foundry](https://book.getfoundry.sh/getting-started/installation) if you don't already have it. Then, run the following commands:

```shell
# Clone the repository
$ git clone git@github.com:whetstoneresearch/doppler.git

# Install the dependencies
$ make install
```

### Testing

```shell
# Copy the example a .env file and fill the RPC endpoints
$ cp .env.example .env

# Then run the tests
$ make test

# You can also only run the invariant tests
$ make fuzz

# And even run longer fuzz tests
$ make deep-fuzz
```

Tests can be tweaked from the `.env` file, this is a nice way to try different testing scenarios without recompiling the contracts:

```shell
IS_TOKEN_0=FALSE
USING_ETH=FALSE
FEE=30
```

### Deploying

Deployment scripts are provided to either deploy the whole protocol or only some specific modules, if you find them in the [script](/script) folder. Note that you will also need to install [Bun](https://bun.sh/), as some internal scripts are written in TypeScript to update the deploment logs and the documentation.

Then make sure to set the required environment variables in the `.env` file before running the deployment scripts, once you're done, you can run the following command to deploy the contracts:

```shell
# Deploy the protocol on Base
make deploy-base

# Deploy the protocol on Unichain
make deploy-unichain

# Deploy the protocol on Ink
make deploy-ink

# Deploy V4 support on Base
make deploy-v4-base

# Deploy V4 support on Unichain
make deploy-v4-unichain

# Deploy V4 support on Ink
make deploy-v4-ink
```
