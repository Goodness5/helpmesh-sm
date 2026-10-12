# Frontend integration note

This is the brief for the Cursor agent building the HelpMesh app against these contracts. Read it in order. Do not ship a screen that talks to a contract until the checklist at the end is true.

Addresses and Basescan links are in `docs/deployments.md`. ABIs are the JSON files in `lib/chain/abis/`. Chain is Base Sepolia, chain id `84532`. RPC `https://sepolia.base.org`.

The UI never imports contract enums into copy. It talks only to `PaymentsProvider`.

## 1. PaymentsProvider

Create `PaymentsProvider` in `lib/chain` with two implementations that share one interface:

- `OnchainPayments` calls the deployed contracts.
- `MockPayments` is in-memory and follows the same states, errors, and delays.
- `DEMO_MODE` swaps them. The mock is labeled **demo chain** in the UI, including the empty and success states.

A testnet outage must leave the demo usable. The screens do not branch on which implementation is active except for that label.

## 2. What stays off-chain

Matching, chat, profiles, accessibility needs, category, description, location, and eligibility-rule text never go in calldata, events, or contract storage.

`requestId` is a `bytes32` the app computes once:

```ts
keccak256(encodePacked(toBytes(requestUuid), secretSalt))
```

`secretSalt` is a random `bytes32` stored only in the database, next to the request. The preimage is never sent to the chain. Every escrow call, voucher, volunteer signature, tip `requestId`, and database row uses that same `bytes32`. A paid, sponsored, and volunteer confirmation cannot share an id: each id can be confirmed once, anywhere.

Do not put a category such as wheelchair assistance next to a wallet. That reveals a disability.

## 3. Token

Only MockUSDC is allowlisted. Name `Mock USDC (test money)`, symbol `mUSDC`, 6 decimals. `10e6` units is $10.00. Divide by `1_000_000` for display. Never show the raw integer as dollars.

Label it test money everywhere it appears, including the faucet, the funding button, and the receipt.

`faucet()` mints 100 tokens to `_msgSender()` at most once per 24 hours. The first call for an address always works. A second call before the cooldown reverts with `FaucetCooldown(nextAt)`. Show the next time in words.

`maxAmount` on the escrow is 10,000 tokens. Funding above that reverts `AmountTooHigh`.

## 4. Gasless calls

Users do not hold gas and do not see a gas prompt. The embedded wallet signs. The relayer submits and pays.

Every user-facing contract uses `_msgSender()` through the trusted forwarder at the address in `docs/deployments.md`. Two paths must both work:

1. The relayer calls `ERC2771Forwarder.execute` with a signed `ForwardRequestData`.
2. A smart account calls the contract directly. Do not also wrap that call in the forwarder.

Appending an address to calldata and calling the contract from a normal wallet does not set the user. Only the trusted forwarder is recognized. A spoofed suffix reverts.

`ForwardRequestData` does not contain the nonce. The signed struct does. Read `forwarder.nonces(from)` at sign time and again at submit time. If they differ, resign.

```text
ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)
```

EIP-712 domain: name `HelpMeshForwarder`, version `1`, `chainId` 84532, verifying contract the forwarder address. `value` is 0. `data` is the encoded contract call. The typehash hashes `keccak256(data)`, not the raw bytes.

Use a `gas` value of at least `500000`. The relayer's outer transaction must supply more than that, or the forwarder's gas check reverts. A reverted `execute` does not consume the nonce, so the same signature can be retried.

The relayer retries with that nonce policy, rate-limits per user, and caps spend per day. On failure the user sees a plain sentence and a **Try again** button. No stack traces, no hex.

## 5. Who signs what

One clear button per action. The embedded wallet produces every signature behind it. The primary UI never shows raw hex or typed-data JSON.

| Action | Who signs | Who submits | Contract call |
|---|---|---|---|
| Fund a requester reward | Requester, twice, behind one button | Relayer | `permit`, then `fundFromRequesterWithPermit` |
| Fund from a pool | Eligibility signer on the server, not the user | Relayer | `fundFromPool` |
| Assign a helper | Nobody. Backend operator key | Operator | `assignHelper` |
| Helper cannot make it | Helper | Relayer | `releaseAssignment` |
| Start help | Helper | Relayer | `start` |
| Mark help done | Helper | Relayer | `complete` |
| Confirm paid or sponsored help | Requester | Relayer | `confirm` |
| Cancel | Requester | Relayer | `cancel` |
| Expire an open request | Anyone, usually the worker | Worker | `expireOpen` |
| Dispute | Requester or helper | Relayer | `dispute` |
| Resolve a dispute | Arbiter key, not the user | Arbiter | `resolve` |
| Auto-release | Anyone, usually the worker | Worker | `autoRelease` |
| Volunteer proof | Requester | Relayer | `attestVolunteer` |
| Tip or support | Sender, after MockUSDC allowance to TipJar | Relayer | `tip` or `support` |
| Faucet | User | Relayer | `faucet` |
| Donate to a pool | Donor | Relayer | `approve` or `permit`, then `deposit` |

On this deployment, admin, operator, eligibility signer, arbiter, and pauser are the same address, `0x5E69f0b90765685f4BFaC82B99A9E4f29e9BaFD1`. The app still treats those jobs as different server keys. Do not put the operator or arbiter key in the client.

`confirm` pays the helper and records the attestation. `resolve` pays a split and does **not** record an attestation. Tips and support never touch `HelpAttestations`.

## 6. EIP-712 domains

All domains use version `1` and chain id `84532`. A signature from another chain or another contract address is invalid.

| Signature | Domain name | Verifying contract | Type |
|---|---|---|---|
| Forwarder request | `HelpMeshForwarder` | Forwarder | `ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,uint48 deadline,bytes data)` |
| Pool voucher | `HelpEscrow` | HelpEscrow | `PoolVoucher(uint64 poolId,bytes32 requestId,address requester,uint128 amount,uint64 openUntil,uint64 expiry)` |
| Volunteer confirmation | `HelpAttestations` | HelpAttestations | `Confirmation(bytes32 requestId,address helper,address requester,uint64 completedAt)` |
| Permit | Read `DOMAIN_SEPARATOR()` from MockUSDC. Do not hardcode it. | MockUSDC | `Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)` |

Permit name inside the token is `Mock USDC (test money)`. Nonce comes from `nonces(owner)` on the token. That nonce is not the forwarder nonce.

Volunteer `completedAt` is a unix second. Use the latest chain block timestamp, not `Date.now()`, so a fast local clock cannot make it a future timestamp. `0` and any future value revert `FutureTimestamp`. The helper and requester must be different addresses.

The pool voucher is signed by the eligibility signer only after the server has checked category, region, eligibility, and per-user limits. On-chain it checks the signature, `expiry`, the pool cap, the pool balance, that the pool is not paused, and that the `requestId` is unused. The user does not see or sign this voucher.

## 7. Reward flow

Behind one button, "Hold $10 as test money until the help is confirmed":

1. Sign a MockUSDC permit. `spender` is HelpEscrow. `value` is the amount. `deadline` is about an hour ahead.
2. Sign a forwarder request whose `data` is `fundFromRequesterWithPermit(requestId, token, amount, openUntil, deadline, v, r, s)`.
3. The relayer submits that request.
4. The database stays "not held" until a `Funded` log for that `requestId` is confirmed. A sent transaction is not enough. A reverted transaction leaves the request unfunded.

`openUntil` must be in the future at funding time. After `openUntil`, anyone can call `expireOpen` and the tokens return to the requester.

Then the operator assigns a helper. The helper calls `start`, then `complete`. The requester calls `confirm`. `confirm` is valid from `Started` or `Completed`. It transfers the full amount to the helper and emits `HelpConfirmed` with kind `Paid` (`0`).

## 8. Sponsored flow

The donor's deposit is irrevocable. The deposit screen says that in words before the signature: the donation cannot be withdrawn, and it can only leave the pool through an eligible request.

`rulesHash` is `keccak256` of the canonical rules JSON stored off-chain and shown on the impact page. If the displayed JSON does not hash to `pools(poolId).rulesHash`, show a mismatch. Listen for `RulesChanged`.

The server signs `PoolVoucher` and the relayer calls `fundFromPool`. Sponsored tokens must never be described as the requester's money. On refund or on the source side of a dispute split, tokens return to `SponsorPool`, and `Refunded.to` is the pool address. Copy for that case is "The sponsored reward went back to the pool", not "Your $10 was returned".

`confirm` on a pool-funded escrow emits `HelpConfirmed` with kind `Sponsored` (`1`).

## 9. Volunteer flow

No escrow and no token movement. The requester signs `Confirmation`. The relayer calls `attestVolunteer`. Kind is `Volunteer` (`2`). The helper cannot sign their own confirmation.

This path is required. Free help produces no escrow event, and the attestation is the only on-chain proof.

## 10. Tips and support

`TipJar` never holds tokens. `tip` and `support` `transferFrom` the sender to the helper in the same call. The sender needs a MockUSDC allowance to TipJar first. Do that with a permit to TipJar, then a forwarded `tip` or `support`, still behind one button.

`tip` carries a `requestId` only as a log. It does not confirm help. Do not add the tip amount to reputation, completions, or the success rate. `support` is a donation to a helper with no request id.

## 11. State copy

Read `escrows(requestId)` when `DEMO_MODE` is off. The getter order is `requester, helper, token, amount, source, poolId, state, openUntil, startedAt, completedAt`.

Numeric states: `None 0`, `Open 1`, `Assigned 2`, `Started 3`, `Completed 4`, `Released 5`, `Refunded 6`, `Disputed 7`, `Resolved 8`.

Never show those names. Fill the amount and the helper's profile name. Example amount `$10`, helper `Daniel`:

| State | Requester sees |
|---|---|
| Open | Your $10 is held safely while we find a helper |
| Assigned | Daniel accepted. Your $10 is still held safely |
| Started | Daniel is helping. Your $10 is held safely |
| Completed | Daniel says the help is done. Please confirm. |
| Released | $10 was paid to Daniel |
| Refunded, requester-funded | Your $10 was returned |
| Refunded, pool-funded | The sponsored reward went back to the pool |
| Disputed | We're looking into this. Your money is safe. |
| Resolved | This was reviewed. $X was paid to Daniel. The rest went back to its source. |

For `Resolved`, read `helperAmount` and `refundAmount` from the `Resolved` event. The remainder is the source's, and pool source means the pool. `helperBps` is 0 to 10000. The contract rounds the helper share down.

`Released.by` is `0` for confirm and `1` for auto-release. The sentence can stay the same. Auto-release happens once `block.timestamp >= completedAt + autoReleaseWindow`. The window is 72 hours.

`cancel` works in `Open` and `Assigned`. In `Started` it works only after `startedAt + maxSessionDuration` (24 hours). It never works after `complete`. Say that in the cancel button's description when the session is still active, instead of offering a cancel that will revert.

Pause blocks new `fundFromRequester`, `fundFromRequesterWithPermit`, and `fundFromPool` only. Confirm, cancel, expire, auto-release, dispute, and resolve still work. If funding reverts with `EnforcedPause`, say that new rewards are paused and existing held money can still be confirmed or returned.

## 12. Signing dialog

The approval step is a react-aria `Dialog`.

- Focus moves into the dialog when it opens.
- The accessible name and description include the amount and the recipient in words.
- Escape cancels and does not submit the signature.
- The result, success or failure, is announced to assistive tech.
- The sentence states what the signature does. For funding: the amount of test money, that it will be held, and that it is paid to the helper only after the requester confirms or the review rules apply.
- For a pool deposit: the amount, and that the donation cannot be taken back.

## 13. Reconciler

A worker reads logs with viem `getLogs`, starting from a stored `lastProcessedBlock`. Wait a few confirmations before writing status. Updates are idempotent on `txHash + logIndex`. Polling is enough. On a reorg, re-read the last N blocks rather than trusting the previous head.

Handle at least these events:

- Escrow: `Funded`, `HelperAssigned`, `AssignmentReleased`, `Started`, `Completed`, `Released`, `Refunded`, `Disputed`, `Resolved`
- Attestations: `HelpConfirmed`
- Pool: `PoolCreated`, `Deposited`, `Drawn`, `Returned`, `RulesChanged`, `PoolPaused`
- TipJar: `Tipped`, `Supported` for the activity feed only, not for reputation
- MockUSDC: `FaucetDripped` if the UI shows a faucet receipt

`HelpConfirmed` fields are `requestId`, `helper`, `requester`, `kind`, `timestamp`. There is no amount and no category. Do not join a payment amount into that record.

Reputation (success rate, volume, consistency, dispute history) is computed off-chain from `HelpConfirmed`, escrow `Disputed`, `Resolved`, and `Refunded`, plus the database. Ignore tips.

Do not mark funds locked in the database until `Funded` is confirmed. If the relayer fails before that, the request is still unfunded and the user can try again.

## 14. Plain errors

Map reverts to sentences. Do not show custom error names as the primary message.

| Revert | Say |
|---|---|
| `EnforcedPause` | New rewards are paused. Money already held can still be confirmed or returned. |
| `FaucetCooldown` | More test money is available at {time}. |
| `AmountTooHigh` | That amount is above the testnet limit. |
| `TokenNotAllowed` | Only test money can be used here. |
| `AlreadyExists` / `AlreadyConfirmed` | This request was already recorded. |
| `SessionActive` | You can cancel after the help session has been left for 24 hours. |
| `TooEarly` | The waiting period is not over yet. |
| `Expired` | That request or approval has expired. |
| `InvalidSignature` | The approval did not match. Try again. |
| `NotRequester` / `NotHelper` | Only the person who made this request, or the assigned helper, can do that. |
| `HelperIsRequester` | You can't confirm your own help. |
| `InsufficientPool` | The sponsorship pool does not have enough for this request. |
| `PoolIsPaused` | This sponsorship pool is paused. |

## 15. Out of scope

Do not add upgradeability, platform fees, a second token, fiat on-ramps, mainnet, a decentralized court, zero-knowledge reputation, or a pool-owner withdrawal. Pool owners cannot withdraw in this version.

## Checklist

- [ ] UI imports `PaymentsProvider` only. `DEMO_MODE` swaps in `MockPayments`, labeled demo chain.
- [ ] `requestId` is `keccak256(encodePacked(uuidBytes, salt))`, and the salt never goes on-chain.
- [ ] No category, description, location, disability, or free text in any contract call.
- [ ] Amounts display with 6 decimals. MockUSDC is called test money.
- [ ] Users do not pay gas. Permit and the forwarder request are hidden behind one button.
- [ ] Funding is not shown as held until `Funded` is confirmed.
- [ ] Sponsored refunds are described as returning to the pool.
- [ ] Volunteer confirmations work with no escrow and no amount.
- [ ] Tips and support do not change `completions` or reputation.
- [ ] State copy matches the table above, including Resolved and both refund cases.
- [ ] The signing dialog is a react-aria `Dialog` with focus, Escape to cancel, amount and recipient in the accessible name, and an announced result.
- [ ] The reconciler is idempotent on `txHash + logIndex` and re-reads the last N blocks after a reorg.
- [ ] Relayer failure shows a plain message and Try again.
- [ ] Direct smart-account calls work without a forwarder wrapper.
