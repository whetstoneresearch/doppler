# INITIALIZERS

Pool initialization contracts for Uniswap V3/V4 integration.

## CORE FILE

**`Doppler.sol` (64KB)** - The heart of the protocol. Implements:
- Bonding curve auction via V4 hooks
- Slug placement (lower, upper, price discovery)
- Epoch-based rebalancing (dutch auction / curve increase)
- Fee accounting with protocol fee exclusion
- Migration readiness checks

## WHERE TO LOOK

| Task | File | Notes |
|------|------|-------|
| Hook lifecycle | `Doppler.sol` | `beforeSwap`, `afterSwap`, `afterInitialize` |
| V4 pool init | `UniswapV4Initializer.sol` | Deploys Doppler via DopplerDeployer |
| Hook init | `DopplerHookInitializer.sol` | For hook-based initialization |
| Multicurve | `UniswapV4MulticurveInitializer.sol` | Multiple curve distribution |
| V3 pools | `UniswapV3Initializer.sol` | V3 initialization (legacy) |

## KEY PATTERNS

### Slug System

```
Lower slug:     [tickLower, currentTick) - holds totalProceeds
Upper slug:     [currentTick, upperTick) - tokens to expected sales
PD slugs[N]:    [upperTick, endTick)     - future epoch tokens
```

### Rebalancing (beforeSwap)

1. Check if new epoch started
2. Compute expected vs actual sales
3. Dutch auction down if undersold, curve up if oversold
4. Update `tickAccumulator`, reposition slugs

### State Tracking (afterSwap)

- `totalTokensSold` - cumulative asset sold
- `totalProceeds` - cumulative numeraire received
- Excludes fees from accounting

## ANTI-PATTERNS

- Never add liquidity externally (`beforeAddLiquidity` reverts)
- Never donate (`beforeDonate` reverts)
- Never swap before `startingTime`
- Never call `migrate()` before maturity + sufficient proceeds

## ERRORS TO KNOW

| Error | Cause |
|-------|-------|
| `CannotAddLiquidity` | External LP attempted |
| `CannotSwapBeforeStartTime` | Too early |
| `SwapBelowRange` | Price below lower slug |
| `MaximumProceedsReached` | Auction complete |
| `CannotMigrate` | Maturity/proceeds not met |
