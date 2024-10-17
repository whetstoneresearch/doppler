# Doppler

Doppler is a liquidity bootstrapping Protocol built on top of Uniswap v4. Doppler abstracts the challenges associated with Uniswap v4 integrations from integrators by executing the entire liquidity bootstrapping auction inside of the hook contract. [Read more](https://whetstone.cc/doppler)

## Curve accumulation

- Places bonding curve according to token sales along a pre-defined schedule based on number of tokens to sell (numTokensToSell) per duration (endingTime - startingTime)
- We rebalance the curve every epoch according to this sales schedule
- If sales are behind schedule, the curve is reduced via a dutch auction mechanism according to the relative amount that we're behind schedule
    - The maximum amount to dutch auction the curve in an epoch is computed as the (endingTick - startingTick) divided by the number of epochs ((endingTime - startingTime) / epochLength)
    - In the case that there was a net sold amount of <=0 (computed as the number of asset tokens swapped out of the curve - the number of asset tokens swapped into the curve) in the previous epoch, we dutch auction the curve by this maximum amount
    - If the net sold amount is greater than 0 but we haven't sold as many tokens as expected (computed as percentage(elapsed time / duration) * numTokensToSell), then we dutch auction the curve by the relative amount we are undersold by applied to the max dutch auction amount, e.g. if we've sold 80% of the expected amount, we're undersold by 20% and thus we dutch auction by 20% of the maximum amount
- If sales are ahead of schedule, i.e. totalTokensSold > expected amount sold (computed as percentage(elapsed time / duration) * numTokensToSell), we move the curve upwards by the amount that we have oversold
    - We compute this increase as the delta between the current tick and the expected tick (this is generally the upperSlug.upperTick, which represents the point at which we have sold the expected amount)
- From whichever of the above outcomes we've hit, we accumulate a tick delta to the tickAccumulator. This value is used to derive the current bonding curve at any given time
    - We derive the lowermost tick of the curve (tickLower) as the startingTick + tickAccumulator
    - We derive the uppermost tick of the curve (tickUpper) as the tickLower + gamma
    - TODO: Other derivations?
    - We can see how the tickAccumulator is accumulated in this [graph](https://www.desmos.com/calculator/fjnd0mcpst), with the red line corresponding to the max dutch auction case, the orange line corresponding to the relative dutch auction case, and the green line corresponding to the oversold case

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```
