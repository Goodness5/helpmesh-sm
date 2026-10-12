# Deployments

## Base Sepolia (chain id 84532)

Verified on [Basescan](https://sepolia.basescan.org). Deployed 8 October 2026.

`0x5E69f0b90765685f4BFaC82B99A9E4f29e9BaFD1` holds admin, operator, eligibility signer, arbiter, and pauser.

| Contract | Address |
|---|---|
| Forwarder | [`0x7ff31538A93950264e26723C959a9D196bfB9779`](https://sepolia.basescan.org/address/0x7ff31538A93950264e26723C959a9D196bfB9779) |
| MockUSDC | [`0x5ba2d923f8b1E392997D87060E207E1BAAeA3E13`](https://sepolia.basescan.org/address/0x5ba2d923f8b1E392997D87060E207E1BAAeA3E13) |
| HelpAttestations | [`0x55633aFf235600374Ef58D2A5e507Aa39C9e0D37`](https://sepolia.basescan.org/address/0x55633aFf235600374Ef58D2A5e507Aa39C9e0D37) |
| SponsorPool | [`0xc9620e577D0C43B5D09AE8EA406eced818402739`](https://sepolia.basescan.org/address/0xc9620e577D0C43B5D09AE8EA406eced818402739) |
| HelpEscrow | [`0x85833f870135671465076793337c4F4Ebee50D34`](https://sepolia.basescan.org/address/0x85833f870135671465076793337c4F4Ebee50D34) |
| TipJar | [`0x1aF8c0651d1724EDf62410cb0B3C7cD459Ed9d2D`](https://sepolia.basescan.org/address/0x1aF8c0651d1724EDf62410cb0B3C7cD459Ed9d2D) |

`autoReleaseWindow` is 72 hours. `maxSessionDuration` is 24 hours. `maxAmount` is 10,000 MockUSDC (6 decimals).

The same record is in `contracts/deployments/84532.json`.
