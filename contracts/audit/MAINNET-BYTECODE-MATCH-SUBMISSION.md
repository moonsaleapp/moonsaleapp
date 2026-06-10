# MoonsaleLottery.sol — Mainnet Bytecode-Match Submission (final sign-off)

Per IGH-2026-005-A §6, submitting the deployed BSC **mainnet** contract for the
bytecode-match confirmation and the final one-page mainnet sign-off letter.

## Deployed contract
- **Address:** `0x6f38134061Bf77d9c504dA6e627C8B5389e97561`
- **Chain:** BNB Smart Chain mainnet (56)
- **Verified source on BscScan:** https://bscscan.com/address/0x6f38134061Bf77d9c504dA6e627C8B5389e97561#code
- **Source = IGH-2026-005-A reviewed source** (the hardened `adminCreditOrphanedFunds` + operator role + the F-01 `setOperator` fix). No code changes since the addendum.

## Constructor arguments (for the bytecode match)
- `_usdt`            = `0x55d398326f99059fF775485246999027B3197955` (BSC USDT)
- `_vrfCoordinator`  = `0xd691f04bc0C9a24Edb78af9E005Cf85768F694C9` (BSC VRF v2.5)
- `_vrfSubscriptionId`= `38345023194297458134405838463885357532102637288811055834341482423275576678620`
- `_vrfKeyHash`      = `0x130dba50ad435d4ecc214aad0d5820474137bd68e7e77724144f27c3c377d3d4` (200 gwei lane)
- `_treasuryWallet`  = `0x91855ab7E0c60Ba8dc6AaAe28E9Bbb0a418b05eD`

## Configuration notes (disclosures)
- **Treasury** is a separate EOA `0x91855…` (not the Safe), intentional and confirmed by the
  team — it only ever holds the 2% treasury cut, never prize/user funds, and is changeable via
  `setRewardDistribution`. (Deviation from cond #1's "treasury = Safe"; disclosed here.)
- **Reward split** set post-deploy and verified on-chain: Match-1 1% / M2 3% / M3 5% / M4 10% /
  M5 25% / Jackpot 54% / treasury 2% (bps 100/300/500/1000/2500/5400 + 200 = 10000).
- **Operator** = `0xe3D3887Ff69199451E9634693F8DE9360533d7b6` (low-privilege cron key; set on-chain).
- **VRF**: subscription funded, contract registered as consumer; mainnet draws confirmed working
  end-to-end (round #1 drew + settled).
- **Ownership:** currently the deployer EOA `0xaD72…`. The team will transfer to the 2-of-2 Gnosis
  Safe `0x4b93C6fD303c24F2e351EF71eB9f8522e3E70c21` (signers `0xaD72` + `0x91855`) via the
  Chainlink two-step `transferOwnership` → `acceptOwnership` before public launch (cond #1).
  We can submit confirmation of the completed transfer for the final letter.

## Request
1. Confirm the deployed mainnet bytecode matches the IGH-2026-005-A reviewed source.
2. Issue the final mainnet sign-off letter (noting the multisig transfer as the remaining
   operational condition, to be confirmed once executed).

---

## IGH-2026-006 conditions — closure evidence

### C-2 (bytecode match, recommended)
- **Mainnet runtime bytecode keccak256:** `0x581fb86b5ca493655f99f7a7cedce04fd0ca55daf65f83dfa0b66134e56eccf4`
- **Length:** 13519 bytes — **byte-for-byte identical length** to the auditor-verified testnet
  contract `0x73FFb254345fB5bb22D4fD70237B45b45a4349AE` (testnet runtime hash
  `0xcfd2b3356c2ef8a71ee8e84b3ba25acdd84c96cefff0ffb1fa30ab8987195b07`).
- The hash differs from testnet **only because of immutables** baked into runtime bytecode
  (VRF coordinator, USDT, subId, keyHash, treasury all differ mainnet-vs-testnet). Same code,
  different embedded constructor constants — expected and benign.
- Source is publicly BscScan-verified; constructor args are listed above so the reviewed source
  can be recompiled and matched against the on-chain creation input. (Creation tx hash available
  from the BscScan contract page header, "Contract Creator … at txn …".)

### C-1 (multisig ownership transfer, blocking pre-launch) — ✅ DONE 2026-05-31
- Ownership transferred to the 2-of-2 Gnosis Safe `0x4b93C6fD303c24F2e351EF71eB9f8522e3E70c21`
  via Chainlink two-step. **Verified on-chain: `owner()` == the Safe.**
  - transferOwnership tx: `0x0bccbc6a8cea3547a7ba7cc457b7372704aef9e6ab225784021be27f128175b0`
  - acceptOwnership tx:   `0x366edc914a95ea052b5206debff2f8a7fae8bcb55302fd0ccb55e829a86e5d07`
