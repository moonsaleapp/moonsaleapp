# MoonSale

A multi-chain EVM presale and fair launch platform deployed on **BNB Smart Chain (BSC)**. Live in production at https://moonsale.app since April 2026.

MoonSale lets token creators raise funds on-chain via fixed-rate presales or contribution-driven fair launches, with automatic DEX listing on PancakeSwap V2 and automatic LP locking the moment a sale finalizes. The platform also provides a token factory, token manager, LP locker, and vesting contracts as a complete launch toolkit.

## Technology Stack

- **Blockchain**: BNB Smart Chain (primary), EVM-compatible chains
- **Smart Contracts**: Solidity ^0.8.20, OpenZeppelin Contracts
- **DEX Integration**: PancakeSwap V2 (BNB Chain), Uniswap V2 (Ethereum)
- **Frontend**: Next.js, React, wagmi, viem
- **Development**: Hardhat, hardhat-verify, TypeChain
- **Verification**: Etherscan V2 API (BscScan / Etherscan unified)

## Supported Networks

- **BNB Smart Chain Mainnet** (Chain ID: 56) LIVE
- **BNB Smart Chain Testnet** (Chain ID: 97) testing environment
- **Ethereum Mainnet** (Chain ID: 1) planned
- **Ethereum Sepolia** (Chain ID: 11155111) testing environment

The platform was designed BNB Chain first. PancakeSwap V2 router (`0x10ED43C718714eb63d5aA57B78B54704E256024E`) is the default DEX integration. All factories are wired to BNB Smart Chain RPC endpoints and PancakeSwap pair contracts by default.

## Contract Addresses

### BNB Smart Chain Mainnet (Chain ID: 56)

| Contract | Address |
|---|---|
| MoonsaleFactory (presale factory) | `0xbfaF3938e3de15Fc887024b3AcC1cDf975Bcfa7D` |
| MoonsalePresale (clone implementation) | `0x0257276759dedfC40F05F6b7e928708e0e1e9Ac5` |
| MoonsaleFairLaunchFactory | `0xe70e643B0ECf01d2d46D35FC73f364CF75D64C5e` |
| MoonsaleFairLaunch (clone implementation) | `0x04f20B211187a4b12Dc164EB529CE4cBd4e3e451` |
| MoonsaleTokenFactory | `0x8D1490006De561C4380e3066a6A1210Bc37A205D` |
| MoonsaleTokenManager | `0x9417D81354b7516d09e46610EE6585Ea56caf10C` |
| MoonsaleTokenLock | `0xd6d969188060516B0ae4Ee3383Cf8FCbC9781b60` |
| MoonsaleTokenVesting | `0x3F5e10AE8B96be923e972f97e37Fa9664071Dc19` |

All contracts are verified on BscScan with publicly readable source code.

## Features

1. **Presale launches on BNB Chain** with softcap, hardcap, configurable presale and listing rates, optional TGE percentage, and post-TGE linear vesting.
2. **Fair launches on BNB Chain** with softcap-only contribution-driven price discovery and optional whitelist gating.
3. **Automatic LP listing on PancakeSwap V2** the instant a sale finalizes, using the raised BNB and the creator-allocated liquidity tokens.
4. **Automatic LP token lock** in the factory contract for a creator-set duration (minimum 30 days). Locks are extend-only by contract design.
5. **Token factory for BEP-20 deployment** with mintable and burnable flags, plus an auto-LP / marketing-fee liquidity generator variant.
6. **Token manager** for fee-gated administrative actions on tokens (mint, burn, ownership transfer).
7. **Standalone LP and token vesting contracts** for team allocations and partner reservations.
8. **On-chain parameter validation** (anti-rug). Server independently re-reads contract state via viem multicall and rejects any UI-submitted value that does not match the deployed contract.
9. **Auto-verified user tokens on BscScan** via Similar Match Source Code, no manual verification per token required.
10. **Configurable platform-level rug protection**: minimum liquidity percentage, minimum lock duration, listing-rate-versus-presale-rate sanity checks, all enforced before a sale is published.

## Build

```bash
npm install
npx hardhat compile
```

## Test

```bash
npx hardhat test
```

## Deploy to BNB Smart Chain

```bash
# BNB Smart Chain Testnet
npx hardhat run scripts/deployFactory.ts --network bscTestnet

# BNB Smart Chain Mainnet
npx hardhat run scripts/deployFactory.ts --network bsc
```

The deploy scripts also auto-verify on BscScan using the V2 unified Etherscan API key configured in `hardhat.config.ts`.

## Audit

Audit briefs covering MoonsalePresale and MoonsaleFairLaunch are in `AUDIT_BRIEF_PRESALE.md` and `AUDIT_BRIEF_FAIRLAUNCH.md`. Contracts pending external audit. Audit reports will be added to the `audit/` directory upon completion.

## Live Application

- Production: https://moonsale.app
- BNB Chain ecosystem: https://www.bnbchain.org

## License

MIT
