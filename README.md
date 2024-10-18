# Doppler

Doppler is a liquidity bootstrapping Protocol built on top of Uniswap v4. Doppler abstracts the challenges associated with Uniswap v4 integrations from integrators by executing the entire liquidity bootstrapping auction inside of the hook contract. [Read more](https://whetstone.cc/doppler)

## Hooks

We make use of 4 Uniswap v4 hook functions in our contract:

- `afterInitialize`
    - Used to place initial liquidity positions
- `beforeSwap`
    - Used to trigger rebalancing of the bonding curve if we haven't yet rebalanced in the current epoch
- `afterSwap`
    - Used to account the total amount of asset tokens sold, `totalTokensSold`, and the total amount of numeraire tokens received from asset sales, `totalProceeds`
    - We exclude the swap fee, consisting of the LP fee and the Uniswap protocol fee, from the accounted amounts such that we don't reinvest LP fees or attempt to reinvest protocol fees taken by Uniswap
- `beforeAddLiquidity`
    - Used to trigger a revert if a user attempts to provide liquidity. This is necessary because we don't want any external liquidity providers

## Curve Accumulation

We rebalance our bonding curve according to token sales along a pre-defined schedule based on the number of tokens to sell, `numTokensToSell`, over the duration, `endingTime - startingTime`. This rebalance occurs immediately preceeding the first swap in every epoch, in the `beforeSwap` hook. If we don't have any swaps in a given epoch then the rebalance applies retroactively to all missed epochs.

### Max Dutch Auction

If sales are behind schedule, the curve is reduced via a dutch auction mechanism according to the relative amount that we're behind schedule. The maximum amount to dutch auction the curve in a single epoch is computed as the `endingTick - startingTick` divided by the total number of epochs, `(endingTime - startingTime) / epochLength`. In the case that there was a net sold amount of zero or less, computed as `totalTokensSold - totalTokensSoldLastEpoch`, we dutch auction the curve by this maximum amount.

### Relative Dutch Auction

If the net sold amount is greater than zero, but we haven't sold as many tokens as expected, computed as `percentage(elapsed time / duration) * numTokensToSell`, then we dutch auction the curve by the relative amount we are undersold by multiplied by the maximum dutch auction amount, e.g. if we've sold 80% of the expected amount, we're undersold by 20% and thus we dutch auction by 20% of the maximum dutch auction amount.

### Oversold Case

If sales are ahead of schedule, i.e. `totalTokensSold` is greater than the expected amount sold, computed as `percentage(elapsed time / duration) * numTokensToSell`, we move the curve upwards by the amount that we have oversold by. We compute this increase as the delta between the current tick and the expected tick, which is generally the upper tick of the upper slug, which represents the point at which we have sold the expected amount (See Liquidity Placement).

### `tickAccumulator`

For whichever of the above outcomes we've hit, we accumulate a tick delta to the `tickAccumulator`. This value is used to derive the current bonding curve at any given time. We derive the lowermost tick of the curve, `tickLower`, as the `startingTick + tickAccumulator`. We derive the uppermost tick of the curve, `tickUpper`, as the `tickLower + gamma`. We can see how the `tickAccumulator` is accumulated in this [graph](https://www.desmos.com/calculator/fjnd0mcpst), with the red line corresponding to the max dutch auction case, the orange line corresponding to the relative dutch auction case, and the green line corresponding to the oversold case.

## Liquidity Placement (Slugs)

Within the bonding curve, we place 3 different types of liquidity positions, aka slugs:
- Lower slug 
    - Positioned below the current price, allowing for all purchased asset tokens to be sold back into the curve
- Upper slug
    - Positioned above the current price, allowing for asset tokens to be purchased, places enough tokens to reach the expected amount of tokens sold
- Price discovery slug(s)
    - Positioned above the upper slug, places enough tokens in each slug to reach the expected amount sold in the next epoch 
    - Hook creators can pick an arbitrary amount of price discovery slugs, up to a maximum amount

### Lower Slug

The lower slug is generally placed ranging from the global tickLower to the current tick. We place the total amount of proceeds from asset sales, `totalProceeds`, into the slug, allowing the users to sell their tokens back into the curve. The lower slug must have enough liquidity to support all tokens being sold back into the curve. 

Ocassionally, we will not have sufficient `totalProceeds` to support all tokens being sold back into the curve with the usual slug placement. In this case, we compute the average clearing price of the tokens, computed as `totalProceeds / totalTokensSold` and place the slug at the tick corresponding to that price with a minimally sized range, i.e. range size of `tickSpacing`.

### Upper Slug

The upper slug is generally placed between the current tick and a delta, computed as `epochLength / duration * gamma`. We supply the delta between the expected amount of tokens sold, computed as `percentage(elapsed time / duration) * numTokensToSell`, and the actual `totalTokensSold`. In the case that `totalTokensSold` is greater than the expected amount of tokens sold, we don't place the slug and instead simply set the ticks in storage both as the current tick.

### Price Discovery Slug

The price discovery slugs are generally placed between the upper slug upper tick and the top the bonding curve, `tickUpper`. The hook creator determines at the time of deployment how many price discovery slugs should be placed. We place the slugs equidistant between the upper slug upper tick and the `tickUpper`, contiguously. We supply tokens in each slug according to the percentage time difference between epochs multiplied by the `numTokensToSell`. Since we're supplying amounts according to remaining epochs, if we run out of future epochs to supply for, we stop placing slugs. In the last epoch there will be no price disovery slugs.

## Usage

### Build

```shell
$ forge build --via-ir
```

### Test

```shell
$ forge test --via-ir
```

### Format

```shell
$ forge fmt
```
