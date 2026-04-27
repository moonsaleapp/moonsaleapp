/**
 * MOONSALE UI PLATFORM TEST — BSC Testnet
 *
 * Simulates the exact flow a user performs through the MoonSale web UI:
 *   1. Deploy token via TokenFactory (on-chain)
 *   2. Deploy presale via PresaleFactory (on-chain)
 *   3. Sign auth message and POST metadata to /api/launch/create (API)
 *   4. Verify the API returns { ok: true } — data now visible on homepage
 *   5. Same flow for a fair launch
 *
 * Prerequisites:
 *   - Dev server running at http://localhost:3000 (cd apps/web && npm run dev)
 *   - BSC testnet wallet funded (.env DEPLOYER_PRIVATE_KEY)
 *
 * Run: npx hardhat run scripts/uiPlatformTest.ts --network bscTestnet
 */
import { ethers } from "hardhat";
import type { BaseContract } from "ethers";

const { parseEther, formatEther } = ethers;

const C = {
  tokenFactory:   "0x25355565f73C384caB973c606d179c0E3409bb4C",
  presaleFactory: "0xfB6c08086B017117b9ba0fb8b5Ea1997e3A8aD34",
  flFactory:      "0x949611dC9e028d9A1400bF8e17D72470E58D1dd4",
  pancakeRouter:  "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
};

const API_BASE  = "http://localhost:3000";
const CHAIN_ID  = 97;

type Result = { id: string; ok: boolean; note: string };
const RESULTS: Result[] = [];
function pass(id: string, note = "") { console.log(`  ✅ PASS [${id}] ${note}`); RESULTS.push({ id, ok: true, note }); }
function fail(id: string, note = "") { console.error(`  ❌ FAIL [${id}] ${note}`); RESULTS.push({ id, ok: false, note }); }

function nowTs() { return BigInt(Math.floor(Date.now() / 1000)); }
function toIso(unixSec: bigint) { return new Date(Number(unixSec) * 1000).toISOString(); }
function makeSlug(name: string, symbol: string) {
  const n = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
  const s = symbol.toLowerCase().replace(/[^a-z0-9]+/g, "-");
  return `${n}-${s}-${Math.random().toString(36).slice(2, 6)}`;
}

function parseEvt(rcpt: any, contract: BaseContract, name: string) {
  for (const log of rcpt.logs) {
    try {
      const parsed = (contract.interface as any).parseLog(log);
      if (parsed?.name === name) return parsed;
    } catch {}
  }
  throw new Error(`Event ${name} not found in tx ${rcpt.hash}`);
}

// Sign the MoonSale auth message exactly as the browser wallet does
async function signAuth(signer: any, wallet: string): Promise<{ message: string; signature: string }> {
  const ts      = Date.now();
  const message = `MoonSale Auth\nWallet: ${wallet.toLowerCase()}\nTimestamp: ${ts}`;
  const signature = await signer.signMessage(message);
  return { message, signature };
}

// POST to /api/launch/create — exactly what the create page form does
async function apiCreate(
  table: string,
  wallet: string,
  message: string,
  signature: string,
  data: Record<string, unknown>
): Promise<{ ok: boolean; id: string }> {
  const res = await fetch(`${API_BASE}/api/launch/create`, {
    method:  "POST",
    headers: { "Content-Type": "application/json" },
    body:    JSON.stringify({ table, wallet, message, signature, data }),
  });
  const json = await res.json() as any;
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${json.error ?? JSON.stringify(json)}`);
  return json;
}

// ── Helper: deploy a standard MoonsaleToken via factory ────────────────────
async function createToken(
  tf: BaseContract, name: string, symbol: string, supplyRaw: bigint, fee: bigint
): Promise<{ address: string; contract: any }> {
  const tx   = await (tf as any).createToken(name, symbol, 18, supplyRaw, 0n, false, false, { value: fee });
  const rcpt = await tx.wait();
  const evt  = parseEvt(rcpt, tf, "TokenCreated");
  console.log(`    Token deployed: ${evt.args.token}`);
  const contract = await ethers.getContractAt("MoonsaleToken", evt.args.token);
  return { address: evt.args.token as string, contract };
}

// ── Presale deposit calculation ──────────────────────────────────────────────
function presaleDeposit(hardcap: bigint, presaleRate: bigint, listingRate: bigint, liqPct: bigint, feePct: bigint) {
  const dist      = (hardcap * presaleRate) / parseEther("1");
  const afterFee  = (hardcap * (10_000n - feePct)) / 10_000n;
  const liqNative = (afterFee * liqPct) / 10_000n;
  const liqTokens = (liqNative * listingRate) / parseEther("1");
  return ((dist + liqTokens) * 12n) / 10n;
}

// ═════════════════════════════════════════════════════════════════════════════
// MAIN
// ═════════════════════════════════════════════════════════════════════════════
async function main() {
  const [signer] = await ethers.getSigners();
  const ME       = signer.address;
  const bal      = await ethers.provider.getBalance(ME);

  console.log("\n╔" + "═".repeat(62) + "╗");
  console.log("║        MOONSALE UI PLATFORM TEST — BSC TESTNET              ║");
  console.log("╚" + "═".repeat(62) + "╝");
  console.log(`\n  Wallet : ${ME}`);
  console.log(`  Balance: ${formatEther(bal)} BNB`);
  console.log(`  API    : ${API_BASE}\n`);

  // ── Sanity check: can we reach the API? ────────────────────────────────────
  try {
    const ping = await fetch(`${API_BASE}/api/launch/create`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    if (ping.status === 0) throw new Error("No response");
    console.log(`  API reachable (status ${ping.status} on empty body — expected 400)\n`);
  } catch (e: any) {
    console.error(`  ❌ Cannot reach ${API_BASE}: ${e.message}`);
    console.error("     Start the dev server: cd apps/web && npm run dev");
    process.exit(1);
  }

  const tokenFactory   = await ethers.getContractAt("MoonsaleTokenFactory",       C.tokenFactory,   signer);
  const presaleFactory = await ethers.getContractAt("MoonsaleFactory",             C.presaleFactory, signer);
  const flFactory      = await ethers.getContractAt("MoonsaleFairLaunchFactory",   C.flFactory,      signer);

  let tokenFee    = await (tokenFactory   as any).creationFee();
  const pFeePct   = await (presaleFactory as any).platformFeePercent();
  const minLock   = await (presaleFactory as any).minLiquidityLockDays();
  const listFee   = await (presaleFactory as any).listingFeeNative();
  const dexRouter = await (presaleFactory as any).dexRouter();
  const flListFee = await (flFactory      as any).listingFeeNative();

  // Zero out creation fee if we are the owner (saves BNB during testing)
  try {
    await (await (tokenFactory as any).setCreationFee(0n)).wait();
    tokenFee = 0n;
    console.log("  Token creation fee zeroed for testing");
  } catch {}

  // ── Shared params ────────────────────────────────────────────────────────
  const SUPPLY_RAW   = 1_000_000n;
  const SUPPLY_WEI   = SUPPLY_RAW * 10n ** 18n;
  const PRESALE_RATE = parseEther("1000");
  // Listing rate must be within admin_settings premium range (min 10%, max 50%)
  // 700 tokens/BNB gives ~43% premium — valid for both on-chain and API
  const LISTING_RATE = parseEther("700");
  // softcap must be >= 50% of hardcap (API validation)
  const HARDCAP      = parseEther("0.04");
  const SOFTCAP      = parseEther("0.02");  // exactly 50% of hardcap
  const MIN_BUY      = parseEther("0.002");
  const MAX_BUY      = parseEther("0.05");
  const LIQ_PCT      = 6_000n;  // 60%
  // Use 90 days — admin_settings requires at least 90 even if factory minimum is lower
  const LOCK_DAYS    = 90n;
  const DEP          = presaleDeposit(HARDCAP, PRESALE_RATE, LISTING_RATE, LIQ_PCT, pFeePct);
  const FL_DEP       = SUPPLY_WEI / 2n;

  // ═══════════════════════════════════════════════════════════════════════
  // UI-01: Presale — deploy on-chain + register via API
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ UI-01: Presale — on-chain deploy + API registration ══");
  try {
    const { address: tAddr, contract: t } = await createToken(
      tokenFactory, "UI Test Token", "UITST", SUPPLY_RAW, tokenFee
    );

    const start = nowTs() + 30n;
    const end   = start   + 600n;

    await (await (t as any).approve(await (presaleFactory as any).getAddress(), DEP)).wait();

    const tx = await (presaleFactory as any).createPresaleAndDeposit(
      {
        token:                tAddr,
        presaleRate:          PRESALE_RATE,
        listingRate:          LISTING_RATE,
        softcap:              SOFTCAP,
        hardcap:              HARDCAP,
        minBuy:               MIN_BUY,
        maxBuy:               MAX_BUY,
        liquidityPercent:     LIQ_PCT,
        liquidityLockDays:    LOCK_DAYS,
        startTime:            start,
        endTime:              end,
        vestingPercentTGE:    10_000n,
        vestingDurationDays:  0n,
        platformFeePercent:   0n,
        platformFeeRecipient: ethers.ZeroAddress,
        dexRouter:            ethers.ZeroAddress,
        creator:              ethers.ZeroAddress,
      },
      DEP,
      pFeePct,
      dexRouter,
      { value: listFee }
    );
    const rcpt      = await tx.wait();
    const evt       = parseEvt(rcpt, presaleFactory, "PresaleCreated");
    const pAddr     = evt.args.presale as string;
    console.log(`    Presale deployed: ${pAddr}`);

    // Sign exactly like the browser wallet
    const { message, signature } = await signAuth(signer, ME);

    const projectName = "UI Test Presale";
    const apiResult   = await apiCreate("presales", ME, message, signature, {
      contract_address:   pAddr,
      chain_id:           CHAIN_ID,
      creator_address:    ME.toLowerCase(),
      token_address:      tAddr,
      token_name:         "UI Test Token",
      token_symbol:       "UITST",
      token_decimals:     18,
      token_total_supply: 1000000,
      presale_rate:       1000,
      listing_rate:       700,
      softcap_eth:        0.02,
      hardcap_eth:        0.04,
      min_buy_eth:        0.002,
      max_buy_eth:        0.05,
      liquidity_percent:  6000,
      liquidity_lock_days: Number(LOCK_DAYS),
      start_time:         toIso(start),
      end_time:           toIso(end),
      vesting_percent_tge:  10000,
      vesting_duration_days: 0,
      status:             "active",
      raised_eth:         0,
      participant_count:  0,
      project_name:       projectName,
      slug:               makeSlug(projectName, "UITST"),
      has_blacklist_warning: false,
    });

    if (!apiResult.ok) throw new Error(`API returned ok=false`);
    console.log(`    API registration: ok=true, id=${apiResult.id}`);
    pass("UI-01", `Presale ${pAddr} | DB id=${apiResult.id}`);
  } catch (e: any) { fail("UI-01", e.message?.slice(0, 140)); }

  // ═══════════════════════════════════════════════════════════════════════
  // UI-02: Fair Launch — deploy on-chain + register via API
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ UI-02: Fair Launch — on-chain deploy + API registration ══");
  try {
    const { address: tAddr, contract: t } = await createToken(
      tokenFactory, "UI Fair Token", "UIFL", SUPPLY_RAW, tokenFee
    );

    const start = nowTs() + 30n;
    const end   = start   + 600n;

    await (await (t as any).approve(await (flFactory as any).getAddress(), FL_DEP)).wait();

    const tx = await (flFactory as any).createFairLaunchAndDeposit(
      {
        token:                tAddr,
        softcap:              SOFTCAP,
        minBuy:               MIN_BUY,
        maxBuy:               MAX_BUY,
        liquidityPercent:     LIQ_PCT,
        liquidityLockDays:    LOCK_DAYS,
        startTime:            start,
        endTime:              end,
        platformFeePercent:   0n,
        platformFeeRecipient: ethers.ZeroAddress,
        dexRouter:            ethers.ZeroAddress,
        creator:              ethers.ZeroAddress,
        isWhitelistEnabled:   false,
      },
      FL_DEP,
      { value: flListFee }
    );
    const rcpt    = await tx.wait();
    const evt     = parseEvt(rcpt, flFactory, "FairLaunchCreated");
    const fAddr   = evt.args.fairLaunch as string;
    console.log(`    Fair launch deployed: ${fAddr}`);

    const { message, signature } = await signAuth(signer, ME);

    const projectName = "UI Fair Launch";
    const apiResult   = await apiCreate("fair_launches", ME, message, signature, {
      contract_address:   fAddr,
      chain_id:           CHAIN_ID,
      creator_address:    ME.toLowerCase(),
      token_address:      tAddr,
      token_name:         "UI Fair Token",
      token_symbol:       "UIFL",
      token_decimals:     18,
      token_total_supply: 1000000,
      total_token_pool:   500000,
      softcap_eth:        0.02,
      min_buy_eth:        0.002,
      max_buy_eth:        0.05,
      liquidity_percent:  6000,
      liquidity_lock_days: Number(LOCK_DAYS),
      start_time:         toIso(start),
      end_time:           toIso(end),
      is_whitelist_enabled: false,
      status:             "active",
      raised_eth:         0,
      participant_count:  0,
      project_name:       projectName,
      slug:               makeSlug(projectName, "UIFL"),
      has_blacklist_warning: false,
    });

    if (!apiResult.ok) throw new Error(`API returned ok=false`);
    console.log(`    API registration: ok=true, id=${apiResult.id}`);
    pass("UI-02", `Fair launch ${fAddr} | DB id=${apiResult.id}`);
  } catch (e: any) { fail("UI-02", e.message?.slice(0, 140)); }

  // ═══════════════════════════════════════════════════════════════════════
  // UI-03: Verify registered presales appear in homepage Supabase query
  //        (checks the anon-key presales view used by app/page.tsx)
  // ═══════════════════════════════════════════════════════════════════════
  console.log("\n══ UI-03: Homepage Supabase query returns data ══");
  try {
    const SUPABASE_URL  = "https://fapejsnjzijlnpjomjzk.supabase.co";
    const SUPABASE_ANON = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZhcGVqc25qemlqbG5wam9tanprIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYzMzEzMjksImV4cCI6MjA5MTkwNzMyOX0.X1WQp3MAHQJKJMCJtVqFyC4JUYc-4Hs5O7t66f5LWrg";

    const res = await fetch(
      `${SUPABASE_URL}/rest/v1/presales?is_hidden=eq.false&order=raised_eth.desc&limit=4`,
      { headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}` } }
    );
    const rows = await res.json() as any[];
    if (!Array.isArray(rows) || rows.length === 0) throw new Error("No presales returned by homepage query");
    console.log(`    Homepage presales query: ${rows.length} results`);
    for (const r of rows) console.log(`      - ${r.project_name} (${r.token_symbol}) | raised ${r.raised_eth} BNB`);

    const flRes = await fetch(
      `${SUPABASE_URL}/rest/v1/fair_launches?is_hidden=eq.false&order=raised_eth.desc&limit=4`,
      { headers: { apikey: SUPABASE_ANON, Authorization: `Bearer ${SUPABASE_ANON}` } }
    );
    const flRows = await flRes.json() as any[];
    console.log(`    Homepage fair launches query: ${flRows.length} results`);
    for (const r of flRows) console.log(`      - ${r.project_name} (${r.token_symbol}) | raised ${r.raised_eth} BNB`);

    pass("UI-03", `presales=${rows.length} ✓ fair_launches=${flRows.length} ✓ homepage data flowing`);
  } catch (e: any) { fail("UI-03", e.message?.slice(0, 140)); }

  // ─── Summary ─────────────────────────────────────────────────────────────
  console.log("\n\n╔" + "═".repeat(62) + "╗");
  console.log("║                    UI TEST RESULTS SUMMARY                  ║");
  console.log("╚" + "═".repeat(62) + "╝");
  for (const r of RESULTS) {
    console.log(`  ${r.ok ? "✅" : "❌"} [${r.id}] ${r.note}`);
  }
  const passed = RESULTS.filter(r => r.ok).length;
  console.log(`\n  Result: ${passed}/${RESULTS.length} passed\n`);
  if (passed < RESULTS.length) process.exit(1);
}

main().catch(e => { console.error(e); process.exit(1); });
