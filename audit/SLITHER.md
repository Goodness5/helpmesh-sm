# Slither notes

Command:

```shell
slither . --fail-medium --filter-paths "lib/|test/|script/" --exclude-dependencies
```

Slither 0.11.6 reports no high or medium findings on `src/`. The notes below are the remaining low and informational results. They are accepted.

## `timestamp` (low)

Expiry, assignment, cancellation, auto-release, and the faucet all compare `block.timestamp` to a stored deadline. That is the rule, not an accident. A miner can nudge the clock by seconds. The windows are 24 hours, 72 hours, or a voucher expiry chosen by the signer, so that nudge does not move funds to a new address. Volunteer `completedAt` is rejected when it is zero or in the future so a confirmation cannot be pre-dated past the present block.

## `reentrancy-benign` on `fundFromRequesterWithPermit` (low)

`permit` is an external call, and the escrow record is written afterward. The function is `nonReentrant`. The only allowlisted token is `MockUSDC`, whose `permit` does not call back. The state written is a new request id, and a second funding of that id reverts with `AlreadyExists`. Pause, admin, and the arbiter still have no path that sends escrowed tokens to an arbitrary address.

## `dead-code` on `_msgData` (informational)

`HelpMeshContext`, `HelpEscrow`, and `MockUSDC` override `_msgData` because they inherit both `Context` and `ERC2771Context`. Solidity requires the override. User identity goes through `_msgSender()`, which calls `_contextSuffixLength()`. Removing `_msgData` does not compile. `test/ContextOverrides.t.sol` executes the overrides.
