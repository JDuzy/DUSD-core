# Stable coin

## Project overview

**DUSD** (Duz usd) is a stablecoin created for educative purposes.
Ans is meant to be a stablecoin where users can deposit WETH and WBTC in exchange for a token that will be pegged to the USD.

DUSD consists of:

- **Relative Stability**: Anchored or Pegged to dollar.
  1. Using Chainlink price feed.
  2. Exchanging ETH & BTC for $USD.
- **Stability Mechanism (Minting)**: Algorithmic (Descentralized)
  1. People can only mint the stable coin with enough collateral (coded)
- **Collateral**: Exogenous (Crypto)
  1. wETH
  2. wBTC

## Liquidation and collateral

There is a threshold of 200%
When a person gives 100$ of ETH as collateral, 50$ DUSD are minted to that person.
Let's suppouse that the ETH value tanks to 74$, that person becomes undercollateralized.

Another user can payback that 50$ DUSD, and in return the new user gets the 74$ ETH collateral from the formerlly person. Making 24$ by liquidating the first user.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
