# Non-custodial escrow — design testbed with measured on-chain costs

A Solidity testbed built to answer one question for a production marketplace,
**with measured numbers instead of intuition**: *what does each on-chain escrow
design actually cost per order, and is it worth it?*

## The rule that can never break

A constraint set by legal counsel, encoded as a contract invariant rather than
a policy document: **a buyer's money can only end up at the seller or back at
the buyer.** The platform fee goes to a wallet fixed at deployment. There is no
general withdrawal function — not even for the contract operator.


## Measured results

### TRON (Nile testnet, real energy prices)

| Option | Energy/order | USD/order |
|---|---|---|
| A — address per order | 181,314 | **6.01** |
| B — shared, one by one | 165,101 | **5.47** |
| B — shared, batches of 5 | 150,088 | **4.97** |

Against a ~2.20 USD fee on a typical order, gas would eat ~3x the fee: **not
viable at that order size on TRON**. Staking TRX for free energy doesn't fix
it either (measured: 1 staked TRX yields 9.58 energy/day → ~63k USD locked for
10 orders/day).

### Same design on BSC: 883x cheaper

The problem was the network's pricing model, not the design. Full purchase
cycle deployed and executed on BSC testnet:

| Step | Gas | USD (mainnet prices) |
|---|---|---|
| Deploy factory (once) | 863,588 | 0.0324 |
| Create order | 543,046 | 0.0204 |
| Release | 86,967 | 0.0033 |
| **Total per order** | **630,013** | **0.0236** — ~1% of the fee |

Portability notes that were verified against both chains, not assumed: USDT
decimals differ (6 on TRON, 18 on BSC); BSC's USDT returns a proper `true`;
Binance's public RPC rejects `eth_getLogs` (the verifier needed RPC failover,
which was exercised by accident in the first live test); and an EVM address
exists on every EVM chain at once, so wrong-network deposits became an
interface-level guard.

## Implementation details that matter

- **solc 0.8.19 pinned, `evmVersion: istanbul`** — from 0.8.20 solc emits
  `PUSH0`, which Tron's TVM does not support. Upgrading the compiler breaks
  deployment.
- **CREATE2 on TVM uses prefix `0x41`** where Ethereum uses `0xff` — verified
  on-chain by comparing the computed address against the real deployment
  (`variants()` existed to settle exactly that question).
- Ephemeral `OrderPayout` takes **no constructor args** so its initcode is
  identical for every order and the address depends only on the salt
  (Uniswap V3 pattern). On-chain code per order: **63 bytes**.

## How the numbers were measured

With `py-solc-x` + `tronpy` against Tron's Nile testnet (free TRX from the
public faucet — no real money involved): deploy both designs, run full
register→release and register→refund cycles, and read the *actual* energy
consumed and the network's *published* energy price rather than estimating
either. The BSC figures come from deploying and executing the full cycle on
BSC testnet, plus `eth_estimateGas` against BSC mainnet to confirm the gas
scale (within 16% of TRON's energy figures for the same bytecode).

