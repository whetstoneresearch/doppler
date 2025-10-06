# Doppler Protocol Event Reference

## Summary
- Total Events: 22
- Total Contracts: 6

## Events by Contract

### Airlock
File: `src/Airlock.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| Create | `Create(address asset, address numeraire, addres...` | `0x68ff1cfcdcf76864161555fc0de1878d8f83ec6949bf351df74d8a4a1a2679ab` |
| Migrate | `Migrate(address asset, address pool)` | `0x2a05bb717043f3a794e94382bf63f2e275ecafc41be9b63c34f16d58da9822ca` |
| SetModuleState | `SetModuleState(address module, ModuleState state)` | `0xff4d9dee81e5531fd6aceab465844fdeddfb1bc498ebe825aa45bc969448bcba` |
| Collect | `Collect(address to, address token, uint256 amount)` | `0x1314fd112a381beea61539dbd21ec04afcff2662ac7d1b83273aade1f53d1b97` |

### Doppler
File: `src/Doppler.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| Rebalance | `Rebalance(int24 currentTick, int24 tickLower, i...` | `0x223157ec47d7bd04fa3ed10c0a8adb38faf97b51ec856a777425a2e39253bd73` |
| Swap | `Swap(int24 currentTick, uint256 totalProceeds, ...` | `0x27db09392d7d230eb65a11bd84925fb8da90df8a067ca8a4fc2933b4f637262b` |
| EarlyExit | `EarlyExit(uint256 epoch)` | `0x628a470bfdde264ef77cd19acfbfca22b3e4413adaf5837ec9fbc0043e35793f` |
| InsufficientProceeds | `InsufficientProceeds()` | `0xe8775e4a58023f399765c3455b45eebcc45ad6b99607a1163f02e1318430970c` |

### IPoolInitializer
File: `src/interfaces/IPoolInitializer.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| Create | `Create(address poolOrHook, address asset, addre...` | `0xb224da6575b2c2ffd42454faedb236f7dbe5f92a0c96bb99c0273dbe98464c7e` |

### IUniswapV2Factory
File: `src/interfaces/IUniswapV2Factory.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| PairCreated | `PairCreated(address token0, address token1, add...` | `0x0d3648bd0f6ba80134a33ba9275ac585d9d315f0ad8355cddefde31afa28d0e9` |

### IUniswapV2Pair
File: `src/interfaces/IUniswapV2Pair.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| Approval | `Approval(address owner, address spender, uint25...` | `0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925` |
| Transfer | `Transfer(address from, address to, uint256 value)` | `0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef` |
| Mint | `Mint(address sender, uint256 amount0, uint256 a...` | `0x4c209b5fc8ad50758f13e2e1088ba56a560dff690a1c6fef26394f4c03821c4f` |
| Burn | `Burn(address sender, uint256 amount0, uint256 a...` | `0xdccd412f0b1252819cb1fd330b93224ca42612892bb3f4f789976e6d81936496` |
| Swap | `Swap(address sender, uint256 amount0In, uint256...` | `0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822` |
| Sync | `Sync(uint112 reserve0, uint112 reserve1)` | `0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1` |

### StreamableFeesLocker
File: `src/StreamableFeesLocker.sol`

| Event | Signature | Topic0 |
|-------|-----------|--------|
| Lock | `Lock(uint256 tokenId, BeneficiaryData[] benefic...` | `0x45429dd41f57211df0cbb08b83d76a6ca40e4fcfe4ca7f71d41b75d6be9cd5e2` |
| Unlock | `Unlock(uint256 tokenId, address recipient)` | `0x027d6c6704a7913d85498305191e7bb755d64034c42fb5169c726408f65b3ce2` |
| DistributeFees | `DistributeFees(uint256 tokenId, uint256 amount0...` | `0x125472b1b527506b5b8381590760f796fd9c88ba5886399d71abc083c6dafa20` |
| Release | `Release(uint256 tokenId, address beneficiary, u...` | `0xab8de90aa60ba5a166ba832ebb0ff724e0fb4440a64c2b043bd78000651c0665` |
| UpdateBeneficiary | `UpdateBeneficiary(uint256 tokenId, address oldB...` | `0xdc49102363197c97922de06511d138180fe1ad161b9d7feb4ee31da1cbef144a` |
| MigratorApproval | `MigratorApproval(address migrator, bool approval)` | `0x372d23d18ee5ba59c4547d05c7a473aeb8e3bf0c4eeb61bff18f3aa46008cdc5` |