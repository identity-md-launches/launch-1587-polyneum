# Polyneum (POLYNEUM)

A fixed-supply ERC-20 token for an IMD custom-token launch on Ethereum (chain id 1).

| Property | Value |
| --- | --- |
| Solidity contract | `Polyneum` (`src/Polyneum.sol`) |
| `name()` | `Polyneum` |
| `symbol()` | `POLYNEUM` |
| `decimals()` | `18` |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18) |
| Constructor arguments | none |
| Minted to | `msg.sender` of the constructor, once |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"` |

## Design

The token is a plain OpenZeppelin v5.1.0 `ERC20` with a constructor that mints the whole supply to
the deployer. That is everything it does. There is deliberately:

- no owner, no admin role, no pause, no blacklist, no freeze, no seize;
- no `mint`, `burn` or `burnFrom`: the supply is fixed forever and can neither grow nor be
  reduced by a privileged hand;
- no fee, tax, burn or reflection on transfer: every transfer moves exactly the amount requested;
- no upgradeability, no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT` in the runtime;
- no external calls from the constructor, so it deploys on an empty chain;
- no `receive`/`fallback`: plain ether sent to the token is rejected.

Because nothing is privileged and nothing is taxed, the launch flows the factory performs
(factory → MerkleDistributor → claimant, factory → PoolManager seed, trader ↔ PoolManager swaps)
all move exactly what they say, and no admin call can later move or freeze a holder's balance.

## Assumptions

- The deployer is whoever sends the creation transaction. On the IMD launch that is the
  ProjectFactory, which receives the full supply and distributes it in its own transactions
  (10% to the swarm's MerkleDistributor, 88% to seed the pool, 2% to the requester's
  `economics.remainderTo`). The token has no knowledge of, and no hard-wired dependency on, any of
  those addresses.
- No value only the requester holds is needed: the token takes no constructor arguments and has no
  owner-settable configuration. There is nothing to set after launch.
- 18 decimals is the ERC-20 default; the manifest must state `decimals: 18` and
  `totalSupply: "1000000000000000000000000000"`.

## Deployment parameters

- Contract name for the manifest: `Polyneum` (8 characters, letters only).
- Constructor arguments: `[]`.
- The launch deploys the token from the bytecode as built by `forge build` with this repository's
  `foundry.toml`. The metadata hash is disabled so the bytes are reproducible.
- `script/DeployPolyneum.s.sol` is a reviewable local deployment entry point. Its `deploy()`
  function is what the tests exercise; `run()` wraps it in a broadcast and reads no environment.
  The IMD launch does not use this script. Nothing in this repository signs or broadcasts anything.

## Operational responsibilities

- **Holder custody.** With no admin powers, nobody can recover tokens sent to a wrong address or
  to a contract that cannot move them. Holders are responsible for their own keys and recipients.
- **Supply distribution.** The deployer holds 100% of the supply at construction. On the IMD
  launch the factory is responsible for forwarding the swarm share, seeding the pool and sending
  the remainder; the token does not enforce or verify that distribution.
- **No upgrade path.** The token cannot be changed after deployment. Any change of behaviour
  requires a new token.
- **Approvals.** Standard ERC-20 allowance semantics apply, including the known
  approve/transferFrom front-running race. Users should set allowances to zero before changing them
  if that matters to them. An allowance of `type(uint256).max` is treated as infinite and is not
  decremented (OpenZeppelin behaviour).

## Open items for the launch (not done here)

- Explorer source verification after deployment, by the network's deployer.
- Independent adversarial review before release; passing tests are not an audit.

## Repository layout

```
foundry.toml                   compiler pins and build settings (root project)
remappings.txt                 forge-std/ and @openzeppelin/contracts/ remappings
src/Polyneum.sol               the token
script/DeployPolyneum.s.sol    local deployment script
test/Polyneum.t.sol            behavioural tests
lib/forge-std/                 vendored forge-std v1.9.6 (src only, plain files)
lib/openzeppelin-contracts/    vendored OpenZeppelin v5.1.0 ERC20 subset (plain files)
```

Dependencies are committed as ordinary files; there are no git submodules and no network access is
needed to build or test.

## Build and test

```
forge build
forge test
forge fmt --check
```

Tests cover: metadata; the single constructor mint to the deployer and its events; transfer and
transferFrom success paths including exact amounts, zero transfers, whole-balance transfers,
infinite allowances and a fuzzed conservation-of-supply check; failure paths for insufficient
balance, insufficient allowance, zero-address receiver and zero-address spender; the launch flows
(swarm share, pool seed, remainder, claim, buy and sell) arriving whole; the absence of any mint,
burn, owner, pause, blacklist or upgrade selector from both a stranger and the deployer; the
deployer's inability to move a holder's balance; rejection of plain ether; and an opcode scan of the
runtime for `DELEGATECALL`, `CALLCODE` and `SELFDESTRUCT`.

Tools run: `forge build`, `forge test` (unit and fuzz, 256 runs), `forge fmt --check`, and the
same test suite under an empty environment. Slither and Mythril were not available in this
environment and did not run.
