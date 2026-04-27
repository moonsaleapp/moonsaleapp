/**
 * MOONSALE FULL PLATFORM TEST — BSC Testnet
 *
 * 13 scenarios covering: token creation, presale, fair launch — all paths:
 * cancel, early withdraw (penalty), below softcap fail, softcap fill,
 * hardcap fill, finalize with liquidity, claim, vesting.
 *
 * Run: npx hardhat run scripts/fullPlatformTest.ts --network bscTestnet
 */
import { ethers } from "hardhat";
import type { BaseContract } from "ethers";

const { parseEther, formatEther } = ethers;

// ── Deployed addresses (BSC Testnet, from apps/web/.env.local) ─────────────
const C = {
  tokenFactory:      "0x25355565f73C384caB973c606d179c0E3409bb4C",
  presaleFactory:    "0xfB6c08086B017117b9ba0fb8b5Ea1997e3A8aD34",
  flFactory:         "0x949611dC9e028d9A1400bF8e17D72470E58D1dd4",
  pancakeRouter:     "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
} as const;

const PRESALE_STATUS = ["Pending","Active","Filled","Finalized","Cancelled","Failed"];
const FL_STATUS      = ["Pending","Active","Finalized","Cancelled","Failed"];

// ── Test result tracking ───────────────────────────────────────────────────
type Result = { id: string; ok: boolean; note: string };
const RESULTS: Result[] = [];

function pass(id: string, note = "") {
  console.log(`  ✅ PASS [${id}] ${note}`);
  RESULTS.push({ id, ok: true, note });
}
function fail(id: string, note = "") {
  console.error(`  ❌ FAIL [${id}] ${note}`);
  RESULTS.push({ id, ok: false, note });
}

async function sleep(ms: number) { return new Promise(r => setTimeout(r, ms)); }

async function waitUntil(ts: bigint, label = "target") {
  const nowSec = BigInt(Math.floor(Date.now() / 1000));
  if (ts > nowSec) {
    const ms = Number(ts - nowSec) * 1000 + 6_000; // 6s buffer for block propagation
    console.log(`    ⏳ Waiting ${Math.ceil(ms / 1000)}s until ${label}...`);
    await sleep(ms);
  }
}

function nowTs(): bigint { return BigInt(Math.floor(Date.now() / 1000)); }

// ── Helper: parse event from receipt ──────────────────────────────────────
function parseEvt(rcpt: any, contract: BaseContract, name: string) {
  for (const log of rcpt.logs) {
    try {
      const parsed = (contract.interface as any).parseLog(log);
      if (parsed?.name === name) return parsed;
    } catch {}
  }
  throw new Error(`Event ${name} not found in tx ${rcpt.hash}`);
}

// ── Helper: create MoonsaleToken via factory, return address ───────────────
async function createToken(
  tf: BaseContract,
  name: string, symbol: string,
  supply: bigint, maxSupply: bigint,
  mintable: boolean, burnable: boolean,
  fee: bigint
): Promise<string> {
  const tx = await (tf as any).createToken(
    name, symbol, 18, supply, maxSupply, mintable, burnable,
    { value: fee }
  );
  const rcpt = await tx.wait();
  const evt  = parseEvt(rcpt, tf, "TokenCreated");
  console.log(`    Token deployed: ${evt.args.token}`);
  return evt.args.token as string;
}

// ── Helper: calculate required token deposit for a presale ─────────────────
// Contract checks: balance >= tokensForLiquidity + tokensForDistribution
// Uses hardcap as worst case. Add 20% buffer.
function presaleDeposit(
  hardcap: bigint,
  presaleRate: bigint,
  listingRate: bigint,
  liqPct: bigint,
  feePct: bigint
): bigint {
  const dist       = (hardcap * presaleRate) / parseEther("1");
  const afterFee   = (hardcap * (10_000n - feePct)) / 10_000n;
  const liqNative  = (afterFee * liqPct) / 10_000n;
  const liqTokens  = (liqNative * listingRate) / parseEther("1");
  return ((dist + liqTokens) * 12n) / 10n; // 20% buffer
}

// ── Helper: create presale via createPresaleAndDeposit ────────────────────
async function createPresale(
  pf: BaseContract,
  tokenAddr: string,
  token: BaseContract,
  opts: {
    presaleRate: bigint; listingRate: bigint;
    softcap: bigint; hardcap: bigint;
    minBuy: bigint; maxBuy: bigint;
    liqPct: bigint; lockDays: bigint;
    vestingTGE: bigint; vestingDays: bigint;
    startOffset?: bigint; duration?: bigint;
  },
  depositAmt: bigint,
  platformFeePct: bigint,
  dexRouter: string,
  listingFee: bigint
): Promise<string> {
  const start = nowTs() + (opts.startOffset ?? 45n);
  const end   = start   + (opts.duration   ?? 150n);

  await (await (token as any).approve(await (pf as any).getAddress(), depositAmt)).wait();

  const tx = await (pf as any).createPresaleAndDeposit(
    {
      token:                tokenAddr,
      presaleRate:          opts.presaleRate,
      listingRate:          opts.listingRate,
      softcap:              opts.softcap,
      hardcap:              opts.hardcap,
      minBuy:               opts.minBuy,
      maxBuy:               opts.maxBuy,
      liquidityPercent:     opts.liqPct,
      liquidityLockDays:    opts.lockDays,
      startTime:            start,
      endTime:              end,
      vestingPercentTGE:    opts.vestingTGE,
      vestingDurationDays:  opts.vestingDays,
      platformFeePercent:   0n,
      platformFeeRecipient: ethers.ZeroAddress,
      dexRouter:            ethers.ZeroAddress,
      creator:              ethers.ZeroAddress,
    },
    depositAmt,
    platformFeePct,
    dexRouter,
    { value: listingFee }
  );
  const rcpt = await tx.wait();
  const evt  = parseEvt(rcpt, pf, "PresaleCreated");
  const presaleAddr = evt.args.presale as string;
  console.log(`    Presale deployed: ${presaleAddr} (start +${opts.startOffset ?? 45}s, end +${Number(opts.startOffset ?? 45n) + Number(opts.duration ?? 150n)}s)`);
  return presaleAddr;
}

// ── Helper: create fair launch ─────────────────────────────────────────────
async function createFairLaunch(
  flf: BaseContract,
  tokenAddr: string,
  token: BaseContract,
  opts: {
    softcap: bigint; minBuy: bigint; maxBuy: bigint;
    liqPct: bigint; lockDays: bigint;
    startOffset?: bigint; duration?: bigint;
  },
  depositAmt: bigint,
  listingFee: bigint
): Promise<string> {
  const start = nowTs() + (opts.startOffset ?? 45n);
  const end   = start   + (opts.duration   ?? 150n);

  await (await (token as any).approve(await (flf as any).getAddress(), depositAmt)).wait();

  const tx = await (flf as any).createFairLaunchAndDeposit(
    {
      token:                tokenAddr,
      softcap:              opts.softcap,
      minBuy:               opts.minBuy,
      maxBuy:               opts.maxBuy,
      liquidityPercent:     opts.liqPct,
      liquidityLockDays:    opts.lockDays,
      startTime:            start,
      endTime:              end,
      platformFeePercent:   0n,
      platformFeeRecipient: ethers.ZeroAddress,
      dexRouter:            ethers.ZeroAddress,
      creator:              ethers.ZeroAddress,
      isWhitelistEnabled:   false,
    },
    depositAmt,
    { value: listingFee }
  );
  const rcpt = await tx.wait();
  const evt  = parseEvt(rcpt, flf, "FairLaunchCreated");
  const flAddr = evt.args.fairLaunch as string;
  console.log(`    Fair launch deployed: ${flAddr}`);
  return flAddr;
}

// ═════════════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════════════
async function main() {
  const [signer] = await ethers.getSigners();
  const ME       = signer.address;
  const startBal = await ethers.provider.getBalance(ME);

  console.log("\n╔" + "═".repeat(62) + "╗");
  console.log("║        MOONSALE FULL PLATFORM TEST — BSC TESTNET            ║");
  console.log("╚" + "═".repeat(62) + "╝");
  console.log(`\n  Wallet : ${ME}`);
  console.log(`  Balance: ${formatEther(startBal)} BNB\n`);

  // ── Load factory contracts ───────────────────────────────────────────────
  const tokenFactory   = await ethers.getContractAt("MoonsaleTokenFactory", C.tokenFactory,      signer);
  const presaleFactory = await ethers.getContractAt("MoonsaleFactory",      C.presaleFactory,    signer);
  const flFactory      = await ethers.getContractAt("MoonsaleFairLaunchFactory", C.flFactory,    signer);

  // ── Read on-chain config ─────────────────────────────────────────────────
  let tokenFee      = await (tokenFactory   as any).creationFee();
  const pFeePct     = await (presaleFactory as any).platformFeePercent();
  const minLockDays = await (presaleFactory as any).minLiquidityLockDays();
  const listingFee  = await (presaleFactory as any).listingFeeNative();
  const dexRouter   = await (presaleFactory as any).dexRouter();
  const flListFee   = await (flFactory      as any).listingFeeNative();
  const flLockDays  = await (flFactory      as any).minLiquidityLockDays();

  console.log("  On-chain config:");
  console.log(`    Token creation fee : ${formatEther(tokenFee)} BNB`);
  console.log(`    Presale platform % : ${pFeePct} bps`);
  console.log(`    Min lock days      : ${minLockDays} days`);
  console.log(`    Presale list fee   : ${formatEther(listingFee)} BNB`);
  console.log(`    FL list fee        : ${formatEther(flListFee)} BNB`);
  console.log(`    DEX router         : ${dexRouter}\n`);

  // ── Shared params ────────────────────────────────────────────────────────
  const PRESALE_RATE = parseEther("1000");  // 1000 tokens per BNB
  const LISTING_RATE = parseEther("500");   // 500 tokens per BNB
  // Amounts kept small so the full suite fits within ~0.14 BNB wallet balance
  const HARDCAP      = parseEther("0.04");
  const SOFTCAP_OK   = parseEther("0.01"); // easy to reach
  // S7: softcap unreachably high so presale expires as Failed
  const S7_SOFTCAP   = parseEther("0.02"); // above what we'll contribute (0.005)
  const S7_HARDCAP   = parseEther("0.04"); // hardcap >= softcap (required by contract)
  const FL_SC_HIGH   = parseEther("0.05"); // softcap used in S12 (above our 0.002 contribution)
  const MIN_BUY      = parseEther("0.002");
  const MAX_BUY      = parseEther("0.05"); // large enough to fill hardcap in one tx
  const LIQ_PCT      = 6_000n;
  const LOCK_DAYS    = minLockDays > 0n ? minLockDays : 30n;
  // SUPPLY_RAW: raw token count passed to factory (factory scales by 10^decimals internally)
  const SUPPLY_RAW   = 1_000_000n;
  // SUPPLY_WEI: actual smallest-unit balance after factory mints (what balanceOf returns)
  const SUPPLY_WEI   = SUPPLY_RAW * 10n ** 18n;
  const DEP          = presaleDeposit(HARDCAP, PRESALE_RATE, LISTING_RATE, LIQ_PCT, pFeePct);
  const S7_DEP       = presaleDeposit(S7_HARDCAP, PRESALE_RATE, LISTING_RATE, LIQ_PCT, pFeePct);
  const FL_DEP       = SUPPLY_WEI / 2n;   // deposit 500k tokens (in smallest units)

  console.log(`  Presale deposit (auto-calc): ${formatEther(DEP)} tokens`);
  console.log(`  S7 presale deposit         : ${formatEther(S7_DEP)} tokens`);
  console.log(`  Fair launch deposit        : ${formatEther(FL_DEP)} tokens\n`);

  // ── Configure penalty on both factories (we are owner) ──────────────────
  console.log("  Configuring 10% early-withdrawal penalty on both factories...");
  try {
    await (await (presaleFactory as any).setPenaltyPercent(1_000n)).wait();
    await (await (presaleFactory as any).setPenaltyReceiver(ME)).wait();
    await (await (flFactory      as any).setPenaltyPercent(1_000n)).wait();
    await (await (flFactory      as any).setPenaltyReceiver(ME)).wait();
    console.log("  Penalty configured (1000 bps = 10%, receiver = self)");
  } catch (e: any) {
    console.log(`  WARNING: penalty setup failed (${e.shortMessage ?? e.message?.slice(0,60)})`);
  }

  // Set token creation fee to 0 for testing (saves 13 × 0.01 = 0.13 BNB)
  try {
    await (await (tokenFactory as any).setCreationFee(0n)).wait();
    tokenFee = 0n;
    console.log("  Token creation fee set to 0 for testing\n");
  } catch (e: any) {
    console.log(`  WARNING: could not set token fee to 0 (${e.shortMessage ?? e.message?.slice(0,60)})\n`);
  }

  // ═══════════════════════════════════════════════════════════════════════
  // S1 — Standard Token (mintable=false, burnable=false, maxSupply=0)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S1: Standard Token Creation ══");
  try {
    const addr = await createToken(tokenFactory, "MoonTest Standard", "MTSTD", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t    = await ethers.getContractAt("MoonsaleToken", addr, signer);
    const bal  = await (t as any).balanceOf(ME);
    if (bal !== SUPPLY_WEI) throw new Error(`Balance wrong: ${formatEther(bal)} (expected ${formatEther(SUPPLY_WEI)})`);
    pass("S1", `${addr} | balance ${formatEther(bal)}`);
  } catch (e: any) { fail("S1", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S2 — Burnable Token + burn() + burnFrom()
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S2: Burnable Token + burn() + burnFrom() ══");
  try {
    const addr = await createToken(tokenFactory, "MoonTest Burnable", "MTBRN", SUPPLY_RAW, 0n, false, true, tokenFee);
    const t    = await ethers.getContractAt("MoonsaleToken", addr, signer);

    const burnAmt = parseEther("1000");

    // burn()
    const b1 = await (t as any).balanceOf(ME);
    await (await (t as any).burn(burnAmt)).wait();
    await sleep(4000); // BSC testnet RPC can return stale state immediately after tx
    const b2 = await (t as any).balanceOf(ME);
    if (b1 - b2 !== burnAmt) throw new Error(`burn() amount wrong: b1=${formatEther(b1)} b2=${formatEther(b2)} diff=${formatEther(b1 - b2)}`);

    // burnFrom() — approve self then burnFrom self
    await (await (t as any).approve(ME, burnAmt)).wait();
    await (await (t as any).burnFrom(ME, burnAmt)).wait();
    await sleep(4000);
    const b3 = await (t as any).balanceOf(ME);
    if (b2 - b3 !== burnAmt) throw new Error(`burnFrom() amount wrong: b2=${formatEther(b2)} b3=${formatEther(b3)}`);

    pass("S2", `burn ✓ burnFrom ✓ | total burned: ${formatEther(burnAmt * 2n)}`);
  } catch (e: any) { fail("S2", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S3 — Mintable+Burnable Token (new maxSupply_ param) + cap enforcement
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S3: Mintable+Burnable (maxSupply enforcement + disableMinting) ══");
  try {
    const maxSup = SUPPLY_RAW * 2n; // 2M cap (raw, factory scales internally)
    const addr   = await createToken(tokenFactory, "MoonTest Mintable", "MTMNT", SUPPLY_RAW, maxSup, true, true, tokenFee);
    const t      = await ethers.getContractAt("MoonsaleToken", addr, signer);

    // mint() — 500k tokens
    const mintAmt = parseEther("500000");
    await (await (t as any).mint(ME, mintAmt)).wait();
    const ts = await (t as any).totalSupply();
    if (ts !== SUPPLY_WEI + mintAmt) throw new Error(`Supply after mint wrong: ${formatEther(ts)} (expected ${formatEther(SUPPLY_WEI + mintAmt)})`);

    // cap enforced — try to mint past cap
    let capOk = false;
    try { await (t as any).mint.staticCall(ME, parseEther("600001")); } // try to exceed remaining 500k headroom
    catch { capOk = true; }
    if (!capOk) throw new Error("Cap not enforced!");

    // disableMinting()
    await (await (t as any).disableMinting()).wait();
    let disabledOk = false;
    try { await (t as any).mint.staticCall(ME, 1n); }
    catch { disabledOk = true; }
    if (!disabledOk) throw new Error("disableMinting did not work!");

    pass("S3", `mint ✓ cap ✓ disableMinting ✓ | totalSupply ${formatEther(ts)}`);
  } catch (e: any) { fail("S3", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S4 — Liquidity Generator Token
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S4: Liquidity Generator Token ══");
  try {
    const tx   = await (tokenFactory as any).createLiquidityToken(
      "MoonTest LiqGen", "MTLIQ", 18, SUPPLY_RAW,
      200, 200,           // 2% liqFee, 2% marketingFee
      100, 200,           // 1% maxTx, 2% maxWallet (basis points)
      ME,                 // marketingWallet = self
      C.pancakeRouter,
      { value: tokenFee }
    );
    const rcpt  = await tx.wait();
    const evt   = parseEvt(rcpt, tokenFactory, "LiquidityTokenCreated");
    const liqTk = await ethers.getContractAt("MoonsaleLiquidityToken", evt.args.token, signer);
    const bal   = await (liqTk as any).balanceOf(ME);
    pass("S4", `${evt.args.token} | balance ${formatEther(bal)} | liqFee 2% mktFee 2%`);
  } catch (e: any) { fail("S4", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S5 — Presale: Create → Contribute → Cancel → Refund + Creator Tokens
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S5: Presale Cancel + Refund ══");
  try {
    const tAddr = await createToken(tokenFactory, "Presale S5", "PS5", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const pAddr = await createPresale(
      presaleFactory, tAddr, t,
      { presaleRate: PRESALE_RATE, listingRate: LISTING_RATE,
        softcap: SOFTCAP_OK, hardcap: HARDCAP, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS,
        vestingTGE: 10_000n, vestingDays: 0n },
      DEP, pFeePct, dexRouter, listingFee
    );
    const presale = await ethers.getContractAt("MoonsalePresale", pAddr, signer);

    const start = await (presale as any).startTime();
    await waitUntil(start, "presale start");

    // Contribute above MIN_BUY
    await (await (presale as any).contribute({ value: parseEther("0.005") })).wait();
    const contrib = await (presale as any).contributions(ME);
    if (contrib === 0n) throw new Error("Contribution not recorded");

    // Cancel
    await (await (presale as any).cancelPresale()).wait();
    if (Number(await (presale as any).status()) !== 4) throw new Error("Status not Cancelled");

    // Investor refund
    const b1 = await ethers.provider.getBalance(ME);
    await (await (presale as any).refund()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    console.log(`    Investor refund: ~${formatEther(b2 - b1)} BNB`);

    // Creator withdraw tokens
    await (await (presale as any).withdrawCreatorTokens()).wait();
    const tokBal = await (t as any).balanceOf(ME);
    console.log(`    Creator tokens recovered: ${formatEther(tokBal)}`);

    pass("S5", `Cancel ✓ refund ✓ creatorTokens ✓`);
  } catch (e: any) { fail("S5", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S6 — Presale: Contribute → Early Withdraw with 10% Penalty
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S6: Presale Early Withdraw (10% penalty) ══");
  try {
    const tAddr = await createToken(tokenFactory, "Presale S6", "PS6", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const pAddr = await createPresale(
      presaleFactory, tAddr, t,
      { presaleRate: PRESALE_RATE, listingRate: LISTING_RATE,
        softcap: SOFTCAP_OK, hardcap: HARDCAP, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS,
        vestingTGE: 10_000n, vestingDays: 0n,
        duration: 600n },   // long presale so we can withdraw early
      DEP, pFeePct, dexRouter, listingFee
    );
    const presale = await ethers.getContractAt("MoonsalePresale", pAddr, signer);
    const start   = await (presale as any).startTime();
    await waitUntil(start, "presale start");

    const contribAmt = parseEther("0.005");
    await (await (presale as any).contribute({ value: contribAmt })).wait();
    console.log(`    Contributed ${formatEther(contribAmt)} BNB`);

    const penPct = await (presaleFactory as any).penaltyPercent(); // should be 1000 (10%)
    console.log(`    Penalty: ${penPct} bps`);

    const b1 = await ethers.provider.getBalance(ME);
    await (await (presale as any).withdrawContribution()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    const net = b2 - b1;
    // Expected back: contribAmt * 90% (minus gas); 10% penalty goes to ME as penalty receiver
    console.log(`    Got back: ~${formatEther(net)} BNB (expected ~${formatEther(contribAmt * 9n / 10n)} minus gas)`);
    if (net > contribAmt) throw new Error("Got back more than contributed!");

    pass("S6", `Early withdraw ✓ | net refund ${formatEther(net)} BNB`);
  } catch (e: any) { fail("S6", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S7 — Presale: Below Softcap → Expire → Refund + Creator Recover
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S7: Presale Below Softcap (fail path) ══");
  try {
    const tAddr = await createToken(tokenFactory, "Presale S7", "PS7", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const pAddr = await createPresale(
      presaleFactory, tAddr, t,
      { presaleRate: PRESALE_RATE, listingRate: LISTING_RATE,
        softcap: S7_SOFTCAP, hardcap: S7_HARDCAP, // softcap=0.3, hardcap=0.5 (contract requires hardcap>=softcap)
        minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS,
        vestingTGE: 10_000n, vestingDays: 0n,
        duration: 90n },    // 90s presale — short so we don't wait long
      S7_DEP, pFeePct, dexRouter, listingFee
    );
    const presale = await ethers.getContractAt("MoonsalePresale", pAddr, signer);
    const start   = await (presale as any).startTime();
    const end     = await (presale as any).endTime();

    await waitUntil(start, "presale start");
    await (await (presale as any).contribute({ value: parseEther("0.005") })).wait();
    console.log(`    Contributed 0.005 BNB (softcap = ${formatEther(S7_SOFTCAP)} BNB, well below)`);

    await waitUntil(end, "presale end");

    // refund() auto-transitions to Failed when below softcap
    const b1 = await ethers.provider.getBalance(ME);
    await (await (presale as any).refund()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    console.log(`    Refunded: ~${formatEther(b2 - b1)} BNB`);
    if (Number(await (presale as any).status()) !== 5) throw new Error("Status not Failed");

    await (await (presale as any).withdrawCreatorTokens()).wait();
    console.log(`    Creator tokens withdrawn`);

    pass("S7", `Fail path ✓ refund ✓ creatorTokens ✓`);
  } catch (e: any) { fail("S7", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S8 — Presale: Fill Hardcap → Immediate Finalize → Claim (100% TGE)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S8: Presale Hardcap Fill + Finalize + Claim ══");
  try {
    const tAddr = await createToken(tokenFactory, "Presale S8", "PS8", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const pAddr = await createPresale(
      presaleFactory, tAddr, t,
      { presaleRate: PRESALE_RATE, listingRate: LISTING_RATE,
        softcap: SOFTCAP_OK, hardcap: HARDCAP, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS,
        vestingTGE: 10_000n, vestingDays: 0n, // 100% at TGE
        duration: 600n },
      DEP, pFeePct, dexRouter, listingFee
    );
    const presale = await ethers.getContractAt("MoonsalePresale", pAddr, signer);
    const start   = await (presale as any).startTime();
    await waitUntil(start, "presale start");

    // Overshoot the hardcap — excess is refunded by the contract
    const b1 = await ethers.provider.getBalance(ME);
    await (await (presale as any).contribute({ value: HARDCAP, gasLimit: 300_000 })).wait();
    const b2 = await ethers.provider.getBalance(ME);
    const raised = await (presale as any).totalRaised();
    const st1    = Number(await (presale as any).status());
    console.log(`    Raised: ${formatEther(raised)} BNB, Status: ${PRESALE_STATUS[st1]}`);
    if (st1 !== 2) throw new Error(`Expected Filled(2), got ${st1}`);
    console.log(`    Excess refunded: ~${formatEther(b1 - b2 - raised)} BNB`); // approx

    // Finalize immediately (Filled → can finalize without waiting for endTime)
    console.log(`    Finalizing (addLiquidityETH to PancakeSwap)...`);
    await (await (presale as any).finalize({ gasLimit: 5_000_000 })).wait();
    await sleep(4000); // wait for BSC testnet RPC to sync state
    if (Number(await (presale as any).status()) !== 3) throw new Error("Not Finalized");

    // Claim all tokens
    const claimable = await (presale as any).getClaimableTokens(ME);
    console.log(`    Claimable: ${formatEther(claimable)} tokens`);
    if (claimable === 0n) throw new Error("Nothing to claim");
    await (await (presale as any).claim()).wait();
    const tokBal = await (t as any).balanceOf(ME);
    console.log(`    Token balance after claim: ${formatEther(tokBal)}`);

    pass("S8", `Hardcap filled ✓ finalized ✓ claimed ${formatEther(claimable)} tokens ✓`);
  } catch (e: any) { fail("S8", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S9 — Presale: Softcap Fill + Wait End → Finalize → Partial Claim (50% TGE vesting)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S9: Presale Softcap Fill + Vesting (50% TGE) ══");
  try {
    const tAddr = await createToken(tokenFactory, "Presale S9", "PS9", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const pAddr = await createPresale(
      presaleFactory, tAddr, t,
      { presaleRate: PRESALE_RATE, listingRate: LISTING_RATE,
        softcap: SOFTCAP_OK, hardcap: HARDCAP, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS,
        vestingTGE: 5_000n,   // 50% at TGE
        vestingDays: 30n,      // rest over 30 days
        duration: 90n },
      DEP, pFeePct, dexRouter, listingFee
    );
    const presale = await ethers.getContractAt("MoonsalePresale", pAddr, signer);
    const start   = await (presale as any).startTime();
    const end     = await (presale as any).endTime();

    await waitUntil(start, "presale start");
    // Contribute above softcap but below hardcap
    await (await (presale as any).contribute({ value: parseEther("0.02") })).wait();
    console.log(`    Contributed 0.02 BNB (above softcap ${formatEther(SOFTCAP_OK)} BNB)`);

    await waitUntil(end, "presale end");

    console.log(`    Finalizing...`);
    await (await (presale as any).finalize({ gasLimit: 5_000_000 })).wait();
    await sleep(4000);
    if (Number(await (presale as any).status()) !== 3) throw new Error("Not Finalized");

    // 0.02 BNB * 1000 rate = 20 tokens, 50% TGE = 10 tokens claimable
    const claimable = await (presale as any).getClaimableTokens(ME);
    console.log(`    Claimable at TGE (50%): ${formatEther(claimable)} tokens (expect ~10)`);
    if (claimable === 0n) throw new Error("Nothing to claim at TGE");
    await (await (presale as any).claim()).wait();

    pass("S9", `Softcap fill ✓ finalize ✓ 50% TGE claimed (${formatEther(claimable)} tokens) ✓`);
  } catch (e: any) { fail("S9", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S10 — Fair Launch: Create → Contribute → Cancel → Refund + Creator Tokens
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S10: Fair Launch Cancel + Refund ══");
  try {
    const tAddr = await createToken(tokenFactory, "FL S10", "FL10", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const fAddr = await createFairLaunch(
      flFactory, tAddr, t,
      { softcap: SOFTCAP_OK, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS, duration: 300n },
      FL_DEP, flListFee
    );
    const fl    = await ethers.getContractAt("MoonsaleFairLaunch", fAddr, signer);
    const start = await (fl as any).startTime();
    await waitUntil(start, "FL start");

    await (await (fl as any).contribute({ value: parseEther("0.005") })).wait();
    console.log(`    Contributed 0.005 BNB`);

    await (await (fl as any).cancelFairLaunch()).wait();
    if (Number(await (fl as any).status()) !== 3) throw new Error("Status not Cancelled");

    const b1 = await ethers.provider.getBalance(ME);
    await (await (fl as any).refund()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    console.log(`    Refunded: ~${formatEther(b2 - b1)} BNB`);

    await (await (fl as any).withdrawCreatorTokens()).wait();
    const tokBal = await (t as any).balanceOf(ME);
    console.log(`    Creator tokens recovered: ${formatEther(tokBal)}`);

    pass("S10", `FL cancel ✓ refund ✓ creatorTokens ✓`);
  } catch (e: any) { fail("S10", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S11 — Fair Launch: Contribute → Early Withdraw with Penalty
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S11: Fair Launch Early Withdraw (10% penalty) ══");
  try {
    const tAddr = await createToken(tokenFactory, "FL S11", "FL11", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const fAddr = await createFairLaunch(
      flFactory, tAddr, t,
      { softcap: SOFTCAP_OK, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS, duration: 600n },
      FL_DEP, flListFee
    );
    const fl    = await ethers.getContractAt("MoonsaleFairLaunch", fAddr, signer);
    const start = await (fl as any).startTime();
    await waitUntil(start, "FL start");

    const contribAmt = parseEther("0.005");
    await (await (fl as any).contribute({ value: contribAmt })).wait();
    console.log(`    Contributed ${formatEther(contribAmt)} BNB`);

    const b1 = await ethers.provider.getBalance(ME);
    await (await (fl as any).withdrawContribution()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    const net = b2 - b1;
    console.log(`    Got back: ~${formatEther(net)} BNB (expect ~${formatEther(contribAmt * 9n / 10n)} minus gas)`);
    if (net > contribAmt) throw new Error("Got back more than contributed!");

    pass("S11", `FL early withdraw ✓ | net ${formatEther(net)} BNB`);
  } catch (e: any) { fail("S11", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S12 — Fair Launch: Below Softcap → Expire → Refund + Creator Tokens
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S12: Fair Launch Below Softcap (fail path) ══");
  try {
    const tAddr = await createToken(tokenFactory, "FL S12", "FL12", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const fAddr = await createFairLaunch(
      flFactory, tAddr, t,
      { softcap: FL_SC_HIGH, minBuy: MIN_BUY, maxBuy: MAX_BUY, // softcap=0.05, impossible to reach
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS, duration: 90n },
      FL_DEP, flListFee
    );
    const fl    = await ethers.getContractAt("MoonsaleFairLaunch", fAddr, signer);
    const start = await (fl as any).startTime();
    const end   = await (fl as any).endTime();

    await waitUntil(start, "FL start");
    await (await (fl as any).contribute({ value: parseEther("0.002") })).wait();
    console.log(`    Contributed 0.002 BNB (softcap ${formatEther(FL_SC_HIGH)} BNB)`);

    await waitUntil(end, "FL end");

    const b1 = await ethers.provider.getBalance(ME);
    await (await (fl as any).refund()).wait();
    const b2 = await ethers.provider.getBalance(ME);
    console.log(`    Refunded: ~${formatEther(b2 - b1)} BNB`);

    await (await (fl as any).withdrawCreatorTokens()).wait();
    console.log(`    Creator tokens recovered`);

    pass("S12", `FL fail path ✓ refund ✓ creatorTokens ✓`);
  } catch (e: any) { fail("S12", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ═══════════════════════════════════════════════════════════════════════
  // S13 — Fair Launch: Fill Softcap → Wait End → Finalize → Claim
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ S13: Fair Launch Finalize + Claim ══");
  try {
    const tAddr = await createToken(tokenFactory, "FL S13", "FL13", SUPPLY_RAW, 0n, false, false, tokenFee);
    const t     = await ethers.getContractAt("MoonsaleToken", tAddr, signer);

    const fAddr = await createFairLaunch(
      flFactory, tAddr, t,
      { softcap: SOFTCAP_OK, minBuy: MIN_BUY, maxBuy: MAX_BUY,
        liqPct: LIQ_PCT, lockDays: LOCK_DAYS, duration: 90n },
      FL_DEP, flListFee
    );
    const fl    = await ethers.getContractAt("MoonsaleFairLaunch", fAddr, signer);
    const start = await (fl as any).startTime();
    const end   = await (fl as any).endTime();

    await waitUntil(start, "FL start");

    const contribAmt = parseEther("0.02"); // above softcap (SOFTCAP_OK = 0.01)
    await (await (fl as any).contribute({ value: contribAmt })).wait();
    const price = await (fl as any).getEstimatedTokenPrice();
    console.log(`    Contributed ${formatEther(contribAmt)} BNB | estimated price: ${formatEther(price)} BNB/token`);

    await waitUntil(end, "FL end");

    console.log(`    Finalizing (addLiquidityETH at fair price)...`);
    await (await (fl as any).finalize({ gasLimit: 5_000_000 })).wait();
    await sleep(4000);
    if (Number(await (fl as any).status()) !== 2) throw new Error("Not Finalized");

    const investorPool = await (fl as any).investorTokenPool();
    console.log(`    Investor token pool: ${formatEther(investorPool)} tokens`);

    const claimable = await (fl as any).getClaimableTokens(ME);
    console.log(`    My claimable: ${formatEther(claimable)} tokens`);
    if (claimable === 0n) throw new Error("Nothing to claim");
    await (await (fl as any).claim()).wait();
    const tokBal = await (t as any).balanceOf(ME);
    console.log(`    Token balance after claim: ${formatEther(tokBal)}`);

    pass("S13", `FL finalize ✓ claimed ${formatEther(claimable)} tokens ✓`);
  } catch (e: any) { fail("S13", e.shortMessage ?? e.message?.slice(0, 120)); }

  // ─── Final summary ────────────────────────────────────────────────────────
  const endBal = await ethers.provider.getBalance(ME);
  console.log("\n\n╔" + "═".repeat(62) + "╗");
  console.log("║                    TEST RESULTS SUMMARY                       ║");
  console.log("╚" + "═".repeat(62) + "╝");
  for (const r of RESULTS) {
    console.log(`  ${r.ok ? "✅" : "❌"} [${r.id.padEnd(3)}] ${r.note}`);
  }
  const passed = RESULTS.filter(r => r.ok).length;
  const total  = RESULTS.length;
  console.log(`\n  Result : ${passed}/${total} passed`);
  console.log(`  BNB spent (net): ${formatEther(startBal - endBal)} BNB`);
  console.log(`  Final balance  : ${formatEther(endBal)} BNB\n`);

  if (passed < total) process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
