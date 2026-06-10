# MoonSale — Multi-Chain EVM Token Launchpad

MoonSale is a production-grade, permissionless presale and fair launch platform deployed on BNB Smart Chain and Base. Token creators can run fixed-rate presales or contribution-driven fair launches with automatic DEX listing, liquidity locking, and on-chain anti-rug protections, no approval required.

Live at [moonsale.app](https://www.moonsale.app)

---

## Deployed Contracts

### BNB Smart Chain Mainnet (Chain 56)

| Contract | Address |
|---|---|
| MoonsaleFactory v2.1 | [`0xD307eE5BF4C505613bE6E4af90B6a2bce7D9CCF1`](https://bscscan.com/address/0xD307eE5BF4C505613bE6E4af90B6a2bce7D9CCF1) |
| MoonsalePresale v2.1 (impl) | [`0x65c770a15a8A17A5e3D78E1c0eaC03Eb93bc8C47`](https://bscscan.com/address/0x65c770a15a8A17A5e3D78E1c0eaC03Eb93bc8C47) |
| MoonsaleFairLaunchFactory | [`0xe70e643B0ECf01d2d46D35FC73f364CF75D64C5e`](https://bscscan.com/address/0xe70e643B0ECf01d2d46D35FC73f364CF75D64C5e) |
| MoonsaleFairLaunch (impl) | [`0x04f20B211187a4b12Dc164EB529CE4cBd4e3e451`](https://bscscan.com/address/0x04f20B211187a4b12Dc164EB529CE4cBd4e3e451) |
| MoonsaleTokenLock | [`0xd6d969188060516B0ae4Ee3383Cf8FCbC9781b60`](https://bscscan.com/address/0xd6d969188060516B0ae4Ee3383Cf8FCbC9781b60) |
| MoonsaleTokenVesting | [`0x3F5e10AE8B96be923e972f97e37Fa9664071Dc19`](https://bscscan.com/address/0x3F5e10AE8B96be923e972f97e37Fa9664071Dc19) |
| MoonsaleTokenFactory | [`0x8D1490006De561C4380e3066a6A1210Bc37A205D`](https://bscscan.com/address/0x8D1490006De561C4380e3066a6A1210Bc37A205D) |
| MoonsaleTokenManager | [`0x9417D81354b7516d09e46610EE6585Ea56caf10C`](https://bscscan.com/address/0x9417D81354b7516d09e46610EE6585Ea56caf10C) |
| MoonsaleLottery | [`0x6f38134061Bf77d9c504dA6e627C8B5389e97561`](https://bscscan.com/address/0x6f38134061Bf77d9c504dA6e627C8B5389e97561) |

### Base Mainnet (Chain 8453)

| Contract | Address |
|---|---|
| MoonsaleFactory | [`0xbfaF3938e3de15Fc887024b3AcC1cDf975Bcfa7D`](https://basescan.org/address/0xbfaF3938e3de15Fc887024b3AcC1cDf975Bcfa7D) |
| MoonsalePresale (impl) | [`0x0257276759dedfC40F05F6b7e928708e0e1e9Ac5`](https://basescan.org/address/0x0257276759dedfC40F05F6b7e928708e0e1e9Ac5) |
| MoonsaleFairLaunchFactory | [`0xe70e643B0ECf01d2d46D35FC73f364CF75D64C5e`](https://basescan.org/address/0xe70e643B0ECf01d2d46D35FC73f364CF75D64C5e) |
| MoonsaleFairLaunch (impl) | [`0x04f20B211187a4b12Dc164EB529CE4cBd4e3e451`](https://basescan.org/address/0x04f20B211187a4b12Dc164EB529CE4cBd4e3e451) |
| MoonsaleTokenLock | [`0xd6d969188060516B0ae4Ee3383Cf8FCbC9781b60`](https://basescan.org/address/0xd6d969188060516B0ae4Ee3383Cf8FCbC9781b60) |
| MoonsaleTokenVesting | [`0x3F5e10AE8B96be923e972f97e37Fa9664071Dc19`](https://basescan.org/address/0x3F5e10AE8B96be923e972f97e37Fa9664071Dc19) |
| MoonsaleTokenFactory | [`0x8D1490006De561C4380e3066a6A1210Bc37A205D`](https://basescan.org/address/0x8D1490006De561C4380e3066a6A1210Bc37A205D) |
| MoonsaleTokenManager | [`0x9417D81354b7516d09e46610EE6585Ea56caf10C`](https://basescan.org/address/0x9417D81354b7516d09e46610EE6585Ea56caf10C) |

All contracts verified on their respective block explorers.

---

## Repository Structure

```
contracts/
  MoonsalePresale.sol            - Fixed-rate presale logic (upgradeable clone proxy)
  MoonsaleFactory.sol            - Presale factory and registry
  MoonsaleFairLaunch.sol         - Contribution-driven fair launch (upgradeable clone proxy)
  MoonsaleFairLaunchFactory.sol  - Fair launch factory and registry
  MoonsaleTokenLock.sol          - LP and token locking with time-lock enforcement
  MoonsaleTokenVesting.sol       - Linear vesting schedules
  tokens/
    MoonsaleTokenFactory.sol     - One-click BEP-20/ERC-20 token creation
    MoonsaleTokenManager.sol     - Post-deploy token admin (mint, burn, renounce)
    MoonsaleToken.sol            - Standard token template
    MoonsaleLiquidityToken.sol   - Liquidity-generating token template
  lottery/
    MoonsaleLottery.sol          - Weekly USDT bracket lottery with Chainlink VRF v2
  interfaces/
    IMoonsalePresale.sol
    IMoonsaleFairLaunch.sol
  audit/
    MAINNET-BYTECODE-MATCH-SUBMISSION.md
    DELTA-REVIEW-BRIEF.md
    F-01-FIX-VERIFICATION.md
    *.diff                       - Audit delta diffs between review rounds

test/
  MoonsalePresale.test.ts
  MoonsaleLottery.test.ts
  AuditFixes.test.ts
  UnsoldHandling.test.ts

scripts/
  deployFactory.ts
  deployFairLaunchFactory.ts
  deployLockVesting.ts
  deployTokenFactory.ts
  deployTokenManager.ts
  deployLottery.ts
```

---

## Features

### Presale

- Fixed-rate token sales with configurable soft cap, hard cap, min/max contribution per wallet
- Automatic PancakeSwap V2 / Uniswap V2 listing on finalization
- Automatic LP token locking (minimum duration enforced by contract)
- Unsold token handling: refund to creator, burn, or lock (creator's choice)
- Optional whitelist gating, togglable by creator at any time
- KYC, audit, and verified-team badges (platform-assigned)
- On-chain parameter validation: listing rate bounds, liquidity %, lock duration

### Fair Launch

- Contribution-driven price discovery, no fixed rate set by creator
- Creator deposits full token supply; final price determined by total raise
- Liquidity carved automatically from the pool at close
- Optional whitelist gating with on/off toggle

### Token Factory

- Deploy standard or liquidity-generating BEP-20/ERC-20 tokens in one transaction
- Auto-verified on BscScan/BaseScan via Similar Match Source Code

### Token Lock and Vesting

- Lock any ERC-20 or LP token with a configurable unlock date (max 10 years)
- Linear vesting schedules with optional cliff

### Weekly Lottery

- Chainlink VRF v2 provably fair randomness
- 6-bracket prize structure (Match 1 through Jackpot), plus 2% treasury
- USDT prize pool; tickets purchased in USDT at a fixed price per ticket
- XP system: platform activity (presale contributions) earns XP redeemable for bonus tickets
- Audited by ICOGemHunters, 91/100, unconditional mainnet sign-off (IGH-2026-006-A)
- 2-of-2 Gnosis Safe multisig owner; separate low-privilege operator key for draws
- Winning claims never expire

---

## Security and Audits

| Scope | Auditor | Score | Report |
|---|---|---|---|
| Presale, FairLaunch, Token contracts | ICOGemHunters | 96/100 | IGH-MSL-2026-015, no open findings |
| MoonsaleLottery | ICOGemHunters | 91/100 | IGH-2026-006-A, unconditional mainnet sign-off |

Audit documents, delta diffs, and the mainnet bytecode-match submission are in `contracts/audit/`.

Platform-level protections enforced at contract level:
- Minimum liquidity percentage (configurable, default 51%)
- Minimum LP lock duration (default 30 days)
- Listing rate sanity bounds
- Pull-based fee model (no fee sent on finalize, creator claims)
- `expectedFeeRecipient` slippage guard against front-running

---

## Tech Stack

- **Solidity** ^0.8.20
- **OpenZeppelin Contracts** v5 (Pausable, ReentrancyGuard, Ownable2Step, clone proxy patterns)
- **Chainlink VRF v2** (lottery randomness)
- **Hardhat** (compile, test, deploy, verify)
- **TypeScript** (deploy scripts, tests)
- **PancakeSwap V2 / Uniswap V2** (DEX integration, same interface across chains)

---

## Development

```bash
cd contracts
npm install
npx hardhat compile
npx hardhat test
```

Deploy to BSC testnet:

```bash
npx hardhat run scripts/deployFactory.ts --network bscTestnet
npx hardhat run scripts/deployFairLaunchFactory.ts --network bscTestnet
npx hardhat run scripts/deployLockVesting.ts --network bscTestnet
npx hardhat run scripts/deployTokenFactory.ts --network bscTestnet
npx hardhat run scripts/deployTokenManager.ts --network bscTestnet
```

Deploy to Base mainnet:

```bash
npx hardhat run scripts/deployFactory.ts --network base
```

Contract verification uses the Etherscan V2 multi-chain API key, which covers BscScan, BaseScan, and Etherscan with a single `ETHERSCAN_API_KEY`.

---

## Supported Networks

| Network | Chain ID | Status |
|---|---|---|
| BNB Smart Chain | 56 | Live |
| Base | 8453 | Live |
| Ethereum | 1 | Planned |
| BNB Testnet | 97 | Testnet |
| Sepolia | 11155111 | Testnet |

---

## License

MIT
