# HelpMesh contracts

Testnet escrow for HelpMesh. Funds move only when a requester confirms, an auto-release window passes, or the arbiter splits a dispute between the helper and the original funding source. Personal data, disability categories, and payment amounts stay off the attestation record.

The chain does four things:

1. Escrow a requester reward until help is confirmed.
2. Hold irrevocable sponsorship-pool donations and pay them out under a signed voucher.
3. Forward tips and support straight to a helper.
4. Record a portable, requester-signed proof of help, including volunteer help where no money moves.

Matching, chat, profiles, and eligibility text stay off-chain. Request ids are `keccak256(requestUuid, secretSalt)`.

## Contracts

| Contract | Role |
|---|---|
| `MockUSDC` | Test token, 6 decimals, ERC-2612 permit, 100 tokens per address per day |
| `HelpEscrow` | Reward state machine |
| `SponsorPool` | Donated balances. Owners cannot withdraw |
| `HelpAttestations` | One confirmation per request. No amount and no category |
| `TipJar` | Non-custodial tips and support |
| `ERC2771Forwarder` | OpenZeppelin trusted forwarder. Users do not pay gas |

Pause blocks new funding only. Confirms, refunds, and payouts stay open.

## Defaults

These are the choices used until you say otherwise:

1. Gas model is the ERC-2771 forwarder, not a paymaster. Demo chain is Anvil (31337). Public testnet broadcast is `script/Deploy.s.sol` plus your RPC and keys.
2. Pool donations are irrevocable.
3. `autoReleaseWindow` is 72 hours. `maxSessionDuration` is 24 hours.
4. The arbiter key is a separate demo key. Dispute resolution is simulated, not a decentralized court.

Admin, operator, eligibility signer, arbiter, and pauser are different addresses. There is no function that sends escrowed tokens to an arbitrary address.

## Develop

```shell
forge test
forge fmt --check
forge coverage --report summary --no-match-coverage 'test/|script/'
forge snapshot
slither . --fail-medium --filter-paths "lib/|test/|script/"
```

Invariant tests run 256 times at depth 50. `audit/SLITHER.md` records any scanner notes.

## Demo and deploy

`pnpm chain:demo` starts Anvil if it is not already running, then runs one requester-funded reward and one sponsored reward. The relayer submits the users' forwarder requests. Anvil's default keys are public and are only for this demo.

```shell
pnpm chain:demo
```

Addresses are written to `contracts/deployments/<chainId>.json`. ABIs for the app are in `lib/chain/abis` (`pnpm abis`).

A public testnet deploy reads `ADMIN_KEY`, `OPERATOR`, `ELIGIBILITY_SIGNER`, `ARBITER`, and `PAUSER`, then:

```shell
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --verify
```

## App handoff

The frontend integration note is `docs/frontend-integration.md`. Follow that file in order. The UI should talk to a `PaymentsProvider` with two implementations, `OnchainPayments` and `MockPayments`, switched by `DEMO_MODE`. The mock must be labeled "demo chain". Do not mark funds locked in the database until a `Funded` log is confirmed. Permit signatures, forwarder requests, and volunteer confirmations stay behind one button.

Plain-language states:

| Contract state | What the user sees |
|---|---|
| Open | Your reward is held safely while we find a helper |
| Assigned | The helper accepted. Your reward is still held safely |
| Started | The helper is helping. Your reward is held safely |
| Completed | The helper says the help is done. Please confirm |
| Released | The reward was paid to the helper |
| Refunded | Your reward was returned |
| Disputed | We're looking into this. Your money is safe |

## Roadmap

Not in this version: upgradeability, platform fees, multiple tokens, fiat on and off ramps, mainnet, decentralized arbitration, zero-knowledge reputation, and organization withdrawals from pools.

## Threats the contracts answer

Helpers cannot take the reward by disappearing. Requesters who ignore a completed request are covered by auto-release, and a started session cannot be cancelled until it is abandoned. Pool payouts need a signed, unexpired, single-use voucher under the pool cap. Admin cannot redirect escrowed funds. Reputation storage has no amount, so tips cannot buy completions.
