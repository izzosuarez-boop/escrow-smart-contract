# Non-custodial escrow — design testbed with measured on-chain costs

A Solidity testbed built to answer one question for a production marketplace,
**with measured numbers instead of intuition**: *what does each on-chain escrow
design actually cost per order, and is it worth it?*

The marketplace it was built for settles buyer→seller payments in USDT. The
payment path went through third-party processors, and three real incidents in
one week (a stuck payment never reported by the processor, an exchange
silently deducting its withdrawal fee from the seller, withdrawals blocked by
minimum-amount rules) motivated evaluating a direct
`buyer → contract → seller` flow.

## The rule that can never break

A constraint set by legal counsel, encoded as a contract invariant rather than
a policy document: **a buyer's money can only end up at the seller or back at
the buyer.** The platform fee goes to a wallet fixed at deployment. There is no
general withdrawal function — not even for the contract operator.

## Two designs, compared

### A — one address per order (`EscrowFactory` + CREATE2)

The backend *computes* a unique payment address per order — nothing is deployed
yet, so this costs zero. The buyer pays that address from anywhere (exchanges
included). To settle, an **ephemeral contract** is deployed at that address: it
distributes the funds inside its own constructor and leaves no code behind.

The key design decision is the salt:

```solidity
salt = keccak256(abi.encode(orderId, buyer, seller))
```

Because the address derives from the salt, and the salt commits to the buyer
and the seller, **the backend cannot divert the funds**: resolving towards any
other party would change the salt, and CREATE2 would deploy at a different —
empty — address. The only freedom left to the operator key is one boolean:
seller or buyer. Anyone can recompute the address from public data and verify
it. Without that binding, a factory with an admin key could send the money
anywhere, and the whole guarantee would be theater.

### B — one shared contract (`SingleEscrow`)

Everyone pays the same address, so the contract can't know which deposit
belongs to which order (contracts can't read chain logs) — the backend
registers deposits. The contract still guarantees `totalCommitted <= balance`
(deposits can't be invented) and that funds only ever reach seller, buyer, or
the fixed fee wallet. Its real advantage: `releaseBatch()` settles N orders in
one transaction. Its real weakness: with a shared address, only the exact
amount distinguishes orders — and amounts arrive *inexact* when exchanges
deduct withdrawal fees on the way out.

## A finding worth knowing: USDT lies about `transfer`

Measured on Tron's Nile testnet: USDT moves the money correctly but **returns
32 zero bytes (`false`)** from `transfer`. The standard OpenZeppelin-style
check

```solidity
require(ok && (data.length == 0 || abi.decode(data, (bool))));
```

**reverts with real USDT** even though the transfer succeeded — meaning no
order could ever be settled, and the failure is token-dependent. The fix in
`SafeTransfer`: verify the *effect*, not the claim — read the recipient's
balance before and after. Two extra reads, works with any token, including the
ones that lie.

The mock token in this repo deliberately reproduces the same defect (return-less
`transfer`), because a lab token that behaves better than the real one makes
tests validate something that doesn't exist. That lesson was also paid for
once: an early mock didn't emit `Transfer`, so log-based payment verification
reported "no payment" with the payment already on-chain.

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

> Scope notes, for honesty: the operator key can't steal funds but can stall
> orders (it deserves separate custody from regular backend credentials);
> late payments after resolution are recoverable by re-deploying at the same
> address but must be planned for; and the code is small but moves real money,
> so a production deployment would warrant an external audit.
