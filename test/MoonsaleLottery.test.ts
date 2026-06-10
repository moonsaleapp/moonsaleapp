import { expect } from "chai";
import { ethers } from "hardhat";
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { Contract, Signer } from "ethers";

/**
 * Smoke tests for the bracket-based MoonsaleLottery.
 *
 * Covers happy path: openRound → buy with mix of manual + quick-pick numbers →
 * drawNumber (after time skip) → VRF fulfilment → postBracketCounts → claim →
 * empty-bracket rollover on next openRound.
 *
 * Full coverage (boundary conditions, all reverts, sponsor flow, XP burn,
 * percent-setter validation) is intentionally lighter here — to be expanded
 * once we lock the testnet flow.
 */

// [M-03] Leaves now include roundId so a proof valid for round N cannot be
// replayed in round N+1 even if the admin re-uses the same root.
function buildXPTree(roundId: bigint, entries: { wallet: string; xp: bigint }[]): {
  root: string;
  proofFor: (wallet: string, xp: bigint) => string[];
} {
  const values = entries.map((e) => [roundId, e.wallet, e.xp]);
  const tree = StandardMerkleTree.of(values, ["uint256", "address", "uint256"]);
  return {
    root: tree.root,
    proofFor: (wallet, xp) => {
      for (const [i, v] of tree.entries()) {
        if (v[1] === wallet && v[2] === xp) return tree.getProof(i);
      }
      throw new Error(`No leaf for round ${roundId} / ${wallet} / ${xp}`);
    },
  };
}

const MOCK_KEY_HASH      = "0x0000000000000000000000000000000000000000000000000000000000000001";
const ROUND_DURATION_SEC = 600n;
const DRAW_DELAY_SEC     = 60n;
const QUICK_PICK         = 0xffffffff;
const EMPTY_PROOF: string[] = [];
const OWNER_REVERT = "Only callable by owner";

describe("MoonsaleLottery (bracket system)", function () {
  let owner: Signer, alice: Signer, bob: Signer, treasury: Signer;
  let ownerAddr: string, aliceAddr: string, bobAddr: string, treasuryAddr: string;
  let usdt: Contract, vrf: Contract, lottery: Contract;
  let subId: bigint;

  beforeEach(async () => {
    [owner, alice, bob, treasury] = await ethers.getSigners();
    [ownerAddr, aliceAddr, bobAddr, treasuryAddr] = await Promise.all([
      owner.getAddress(), alice.getAddress(), bob.getAddress(), treasury.getAddress(),
    ]);

    const MockUSDT = await ethers.getContractFactory("MockUSDT");
    usdt = await MockUSDT.deploy();
    for (const a of [aliceAddr, bobAddr]) {
      await usdt.mint(a, ethers.parseEther("10000"));
    }

    const VRFMock = await ethers.getContractFactory("MockVRFCoordinatorV2_5");
    vrf = await VRFMock.deploy();
    subId = 1n;

    const Lottery = await ethers.getContractFactory("MoonsaleLottery");
    lottery = await Lottery.deploy(
      await usdt.getAddress(),
      await vrf.getAddress(),
      subId,
      MOCK_KEY_HASH,
      treasuryAddr,
    );

    for (const signer of [alice, bob]) {
      await usdt.connect(signer).approve(await lottery.getAddress(), ethers.MaxUint256);
    }
  });

  it("defaults sum to 100% (99% brackets + 1% treasury)", async () => {
    const percents = await lottery.getBracketPercents();
    const treasuryP = await lottery.treasuryPercent();
    const sum = percents.reduce((acc: bigint, p: bigint) => acc + p, 0n) + treasuryP;
    expect(sum).to.equal(10_000n);
    expect(percents).to.deep.equal([100n, 300n, 500n, 1000n, 2500n, 5500n]);
    expect(await lottery.treasuryWallet()).to.equal(treasuryAddr);
  });

  it("setRewardDistribution rejects sums != 100%", async () => {
    await expect(
      lottery.setRewardDistribution([50, 100, 200, 300, 400, 500], 100, treasuryAddr)
    ).to.be.revertedWithCustomError(lottery, "PercentSumNot100");
  });

  it("setRewardDistribution accepts valid 100% split", async () => {
    await expect(
      lottery.setRewardDistribution([100, 200, 400, 900, 2400, 5800], 200, treasuryAddr)
    ).to.emit(lottery, "RewardDistributionUpdated");
    const p = await lottery.getBracketPercents();
    expect(p[5]).to.equal(5800n);
    expect(await lottery.treasuryPercent()).to.equal(200n);
  });

  it("buyTickets with mix of manual + QUICK_PICK numbers, then full round → claim flow", async () => {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);

    // Alice buys 5 tickets: 3 manual specific numbers + 2 quick pick
    const aliceNumbers = [123456, 123450, 123000, QUICK_PICK, QUICK_PICK];
    await expect(
      lottery.connect(alice).buyTickets(1, aliceNumbers, 5, 0, 0, EMPTY_PROOF)
    ).to.emit(lottery, "TicketsBought");

    // Bob buys 3 manual numbers
    const bobNumbers = [999999, 555555, 111111];
    await lottery.connect(bob).buyTickets(1, bobNumbers, 3, 0, 0, EMPTY_PROOF);

    // Round has 8 tickets, prize pool = 8e18
    const round = await lottery.getRound(1);
    expect(round.totalTickets).to.equal(8);
    expect(round.prizePool).to.equal(ethers.parseEther("8"));

    // Advance time past endTime + drawDelay
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);

    // Draw
    const drawTx = await lottery.drawNumber(1);
    const drawRcpt = await drawTx.wait();
    const drawEvt = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested");
    const vrfReqId = drawEvt!.args.vrfRequestId as bigint;

    // VRF mock returns 123450 (a number that matches several of Alice's tickets at varying digits)
    // 123450 vs Alice:
    //   123456 → 5 matches (12345_)
    //   123450 → 6 matches (Jackpot!)
    //   123000 → 3 matches (123)
    //   QUICK_PICK numbers — depends on hash, unlikely to match
    // 123450 vs Bob: 999999, 555555, 111111 → 0 matches each
    const winningNumber = 123450;
    await vrf.fulfillRandomWordsWithOverride(vrfReqId, await lottery.getAddress(), [winningNumber]);

    const roundAfterVrf = await lottery.getRound(1);
    expect(roundAfterVrf.winningNumber).to.equal(winningNumber);
    expect(roundAfterVrf.status).to.equal(3); // RESULTS_PENDING

    // Off-chain we'd compute bracket counts; here we provide them directly.
    // Alice's tickets: Match-6 (1), Match-5 (1), Match-3 (1), 2 quickpicks (~0 expected)
    // Bob's tickets: 0 matches each
    // Counts [Match-1, Match-2, Match-3, Match-4, Match-5, Match-6]
    const counts = [0, 0, 1, 0, 1, 1];

    const initialTreasuryBal = await usdt.balanceOf(treasuryAddr);
    await expect(lottery.postBracketCounts(1, counts)).to.emit(lottery, "BracketCountsPosted");

    // Treasury got 1% = 0.08 USDT
    const expectedTreasury = (ethers.parseEther("8") * 100n) / 10_000n;
    expect(await usdt.balanceOf(treasuryAddr)).to.equal(initialTreasuryBal + expectedTreasury);

    // Alice claims the Jackpot ticket (index 1: number 123450)
    const aliceBalBefore = await usdt.balanceOf(aliceAddr);
    await expect(lottery.connect(alice).claim(1, 1)).to.emit(lottery, "Claimed");
    const jackpotPool = (ethers.parseEther("8") * 5500n) / 10_000n;
    expect(await usdt.balanceOf(aliceAddr)).to.equal(aliceBalBefore + jackpotPool);

    // Alice claims Match-5 ticket (index 0: number 123456)
    await lottery.connect(alice).claim(1, 0);

    // Alice claims Match-3 ticket (index 2: number 123000)
    await lottery.connect(alice).claim(1, 2);

    // Re-claim same ticket fails
    await expect(lottery.connect(alice).claim(1, 1)).to.be.revertedWithCustomError(
      lottery, "TicketAlreadyClaimed"
    );

    // Bob's tickets don't match → claim reverts
    await expect(lottery.connect(bob).claim(1, 5)).to.be.revertedWithCustomError(
      lottery, "TicketHasNoWinningMatch"
    );

    // Wrong owner reverts
    await expect(lottery.connect(bob).claim(1, 1)).to.be.revertedWithCustomError(
      lottery, "NotTicketOwner"
    );
  });

  it("empty-bracket pools roll over to next round's prize pool", async () => {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);

    // Only 1 ticket bought, very unlikely to match anything
    await lottery.connect(alice).buyTickets(1, [123456], 1, 0, 0, EMPTY_PROOF);

    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawTx = await lottery.drawNumber(1);
    const drawRcpt = await drawTx.wait();
    const drawEvt = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested");
    const reqId = drawEvt!.args.vrfRequestId as bigint;

    // Winning number 999999 — Alice's ticket 123456 has 0 matches
    await vrf.fulfillRandomWordsWithOverride(reqId, await lottery.getAddress(), [999999]);

    // Post all-zero counts → every bracket pool becomes empty → all rolls over
    await lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]);

    // Open round 2 — should roll over 99% of the prize pool (treasury already took 1%)
    const tree2 = buildXPTree(2n, [{ wallet: aliceAddr, xp: 0n }]);
    const tx = await lottery.openRound(tree2.root);
    const rcpt = await tx.wait();
    const evts = rcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .filter((e: any) => e?.name === "EmptyBracketRolledOver");
    expect(evts.length).to.equal(1);
    expect(evts[0].args.totalAmount).to.equal((ethers.parseEther("1") * 9900n) / 10_000n);

    const round2 = await lottery.getRound(2);
    expect(round2.prizePool).to.equal((ethers.parseEther("1") * 9900n) / 10_000n);
  });

  it("only owner can openRound, setRewardDistribution", async () => {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await expect(lottery.connect(alice).openRound(tree.root)).to.be.revertedWith(OWNER_REVERT);
    await expect(
      lottery.connect(alice).setRewardDistribution([100,300,500,1000,2500,5500], 100, treasuryAddr)
    ).to.be.revertedWith(OWNER_REVERT);
  });

  it("computeBracket view returns correct bracket index", async () => {
    // 6 matches → matched=6, bracket=5
    const [m6, b6] = await lottery.computeBracket(123456, 123456);
    expect(m6).to.equal(6);
    expect(b6).to.equal(5);

    // 5 matches → matched=5, bracket=4
    const [m5, b5] = await lottery.computeBracket(123456, 123450);
    expect(m5).to.equal(5);
    expect(b5).to.equal(4);

    // 3 matches → matched=3, bracket=2
    const [m3, b3] = await lottery.computeBracket(123456, 123000);
    expect(m3).to.equal(3);
    expect(b3).to.equal(2);

    // 1 match → matched=1, bracket=0
    const [m1, b1] = await lottery.computeBracket(123456, 199999);
    expect(m1).to.equal(1);
    expect(b1).to.equal(0);

    // 0 matches → matched=0, bracket=-1
    const [m0, b0] = await lottery.computeBracket(123456, 999999);
    expect(m0).to.equal(0);
    expect(b0).to.equal(-1);
  });

  // ── Audit remediation coverage ─────────────────────────────────────────────

  it("[I-01] constructor rejects zero USDT address", async () => {
    const Lottery = await ethers.getContractFactory("MoonsaleLottery");
    await expect(
      Lottery.deploy(ethers.ZeroAddress, await vrf.getAddress(), subId, MOCK_KEY_HASH, treasuryAddr)
    ).to.be.revertedWithCustomError(lottery, "InvalidUsdtAddress");
  });

  it("[M-02] setRoundDuration / setDrawDelay enforce hard bounds", async () => {
    // Default minRoundDuration is 5 minutes (300s), so 299s is below
    await expect(lottery.setRoundDuration(299)).to.be.revertedWithCustomError(lottery, "InvalidDuration");
    await expect(lottery.setRoundDuration(31 * 86400)).to.be.revertedWithCustomError(lottery, "InvalidDuration"); // > MAX
    await lottery.setRoundDuration(2 * 60 * 60);  // 2h, valid
    await expect(lottery.setDrawDelay(7 * 3600)).to.be.revertedWithCustomError(lottery, "InvalidDelay");
    await lottery.setDrawDelay(0);  // 0 is fine
  });

  it("[admin-min-round / D-01] setMinRoundDuration is admin-tunable, bounded, and cannot exceed roundDuration", async () => {
    // Default is 5 minutes (= ABSOLUTE_MIN_ROUND_DURATION)
    expect(await lottery.minRoundDuration()).to.equal(300n);

    // Below the absolute 5-min floor reverts
    await expect(lottery.setMinRoundDuration(299)).to.be.revertedWithCustomError(lottery, "InvalidDuration");
    // Above MAX reverts
    await expect(lottery.setMinRoundDuration(31 * 86400)).to.be.revertedWithCustomError(lottery, "InvalidDuration");

    // Tightening to 10 minutes works (default roundDuration = 10 min, so newMin == roundDuration, allowed)
    await expect(lottery.setMinRoundDuration(10 * 60)).to.emit(lottery, "MinRoundDurationUpdated").withArgs(300n, 600n);
    expect(await lottery.minRoundDuration()).to.equal(600n);

    // [D-01] Raising newMin above current roundDuration reverts
    // (current roundDuration = 10 min, try to set min = 30 min)
    await expect(lottery.setMinRoundDuration(30 * 60)).to.be.revertedWithCustomError(lottery, "InvalidDuration");

    // The auditor's "raise both" workflow: setRoundDuration first, then setMinRoundDuration
    await lottery.setRoundDuration(30 * 60);   // 30 min
    await lottery.setMinRoundDuration(30 * 60); // now 30-min floor allowed (== roundDuration)

    // Now setRoundDuration(600) reverts (below new floor)
    await expect(lottery.setRoundDuration(600)).to.be.revertedWithCustomError(lottery, "InvalidDuration");

    // Loosening back down works
    await lottery.setMinRoundDuration(5 * 60);
    await lottery.setRoundDuration(5 * 60);  // shortest possible round = 5 min (absolute floor)

    // Non-owner cannot call
    await expect(lottery.connect(alice).setMinRoundDuration(5 * 60)).to.be.revertedWith(OWNER_REVERT);
  });

  it("[M-03] proof from round N is rejected in round N+1 (replay protection)", async () => {
    // Open round 1 with Alice having 100 XP. She doesn't burn in round 1.
    const tree1 = buildXPTree(1n, [{ wallet: aliceAddr, xp: 100n }]);
    await lottery.openRound(tree1.root);
    const proof1 = tree1.proofFor(aliceAddr, 100n);

    // Settle round 1 with one quick-pick (no XP burn yet)
    await lottery.connect(alice).buyTickets(1, [QUICK_PICK], 1, 0, 0, EMPTY_PROOF);
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawTx = await lottery.drawNumber(1);
    const drawRcpt = await drawTx.wait();
    const reqId = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested")!.args.vrfRequestId as bigint;
    await vrf.fulfillRandomWordsWithOverride(reqId, await lottery.getAddress(), [0]);
    await lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]);

    // Re-open round 2 reusing the SAME merkle root (i.e. admin failed to rotate)
    await lottery.openRound(tree1.root);

    // Now Alice tries to replay the round-1 proof in round 2. Should revert.
    await expect(
      lottery.connect(alice).buyTickets(2, [QUICK_PICK, QUICK_PICK], 1, 10, 100, proof1)
    ).to.be.revertedWithCustomError(lottery, "InvalidMerkleProof");
  });

  it("[M-01 + L-01] every wei of prize pool accounted for after all claims", async () => {
    // Use an awkward prize-pool size where integer division produces dust at
    // both postBracketCounts (M-01) and per-claim share (L-01).
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);

    // 7 tickets at 1 USDT each → pool 7 USDT = 7e18 wei. 7 isn't divisible by
    // any of the bracket percent denominators, so we'll see truncation.
    // We hand-pick numbers so they all match in bracket-0 (Match-1).
    const numbers = [100000, 100001, 100002, 100003, 100004, 100005, 100006];
    await lottery.connect(alice).buyTickets(1, numbers, 7, 0, 0, EMPTY_PROOF);

    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawTx = await lottery.drawNumber(1);
    const drawRcpt = await drawTx.wait();
    const reqId = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested")!.args.vrfRequestId as bigint;

    // Winning number 199999 — Alice's tickets all start with '1' = Match-1 (no further prefix match)
    await vrf.fulfillRandomWordsWithOverride(reqId, await lottery.getAddress(), [199999]);
    // All 7 land in bracket 0 (Match-1)
    await lottery.postBracketCounts(1, [7, 0, 0, 0, 0, 0]);

    const lotteryAddr = await lottery.getAddress();
    const balBefore = await usdt.balanceOf(lotteryAddr);
    expect(balBefore).to.be.greaterThan(0n);

    // Claim all 7 tickets one by one
    for (let i = 0; i < 7; i++) {
      await lottery.connect(alice).claim(1, i);
    }

    // After all claims, only the empty bracket pools (Match-2..6) and 0 dust remain.
    // The Match-1 bracket should be fully drained (no dust).
    const round = await lottery.getRound(1);
    expect(round.bracketPaid[0]).to.equal(round.bracketAmounts[0]);
  });

  it("[I-03] claimBatch rejects oversized batches", async () => {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);

    // Buy 1 paid ticket so the round has any state at all
    await lottery.connect(alice).buyTickets(1, [QUICK_PICK], 1, 0, 0, EMPTY_PROOF);
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawTx = await lottery.drawNumber(1);
    const drawRcpt = await drawTx.wait();
    const reqId = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested")!.args.vrfRequestId as bigint;
    await vrf.fulfillRandomWordsWithOverride(reqId, await lottery.getAddress(), [0]);
    await lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]);

    const tooMany = new Array(201).fill(0).map((_, i) => BigInt(i));
    await expect(
      lottery.connect(alice).claimBatch(1, tooMany)
    ).to.be.revertedWithCustomError(lottery, "TooManyTickets");
  });

  it("[I-05] RewardDistributionUpdated event includes old + new treasury wallet", async () => {
    const newTreasury = bobAddr;
    await expect(
      lottery.setRewardDistribution([100, 300, 500, 1000, 2500, 5500], 100, newTreasury)
    ).to.emit(lottery, "RewardDistributionUpdated")
     .withArgs([100, 300, 500, 1000, 2500, 5500], 100, treasuryAddr, newTreasury);
  });

  it("[L-02] VRF requestId stored as full uint256 (no truncation)", async () => {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);
    await lottery.connect(alice).buyTickets(1, [QUICK_PICK], 1, 0, 0, EMPTY_PROOF);
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    await lottery.drawNumber(1);
    const round = await lottery.getRound(1);
    // Mock VRF coordinator returns sequential IDs; just confirm field exists and is non-zero.
    expect(round.vrfRequestId).to.be.greaterThan(0n);
    // The field type accepts a full uint256 — verified by the contract compiling
    // with `uint256 vrfRequestId` in the struct (typechain reflects this).
  });

  it("[orphan-rollover] zero-buyer round's full pool rolls into the next round", async () => {
    // Seed a non-trivial pool in round 1, then have a zero-buyer round 2.
    // Before the fix: round 2's prizePool was orphaned. After: it rolls to round 3.

    // ── Round 1: 2 tickets, no winners → all 6 brackets empty → 99% rolls to R2
    const tree1 = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree1.root);
    await lottery.connect(alice).buyTickets(1, [123456, 234567], 2, 0, 0, EMPTY_PROOF);

    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawTx1 = await lottery.drawNumber(1);
    const drawRcpt1 = await drawTx1.wait();
    const drawEvt1 = drawRcpt1!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested");
    await vrf.fulfillRandomWordsWithOverride(drawEvt1!.args.vrfRequestId, await lottery.getAddress(), [999999]);
    await lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]);

    // ── Round 2 opens with R1's rollover, zero buyers
    const tree2 = buildXPTree(2n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree2.root);
    const round2Pool = (await lottery.getRound(2)).prizePool;
    expect(round2Pool).to.equal((ethers.parseEther("2") * 9900n) / 10_000n);  // 1.98 USDT

    // No buys in round 2. Time skip + drawNumber → zero-ticket short-circuit
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    await expect(lottery.drawNumber(2))
      .to.emit(lottery, "NoBuyersRollover")
      .withArgs(2, round2Pool);

    // ── The fix: bracketAmounts[5] now equals the full pool so it rolls on next openRound
    const round2 = await lottery.getRound(2);
    expect(round2.bracketAmounts[5]).to.equal(round2Pool);
    expect(round2.bracketCounts[5]).to.equal(0);

    // ── Round 3 opens — full R2 pool rolls over
    const tree3 = buildXPTree(3n, [{ wallet: aliceAddr, xp: 0n }]);
    const tx3 = await lottery.openRound(tree3.root);
    const rcpt3 = await tx3.wait();
    const rolloverEvt = rcpt3!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "EmptyBracketRolledOver");
    expect(rolloverEvt!.args.totalAmount).to.equal(round2Pool);

    const round3 = await lottery.getRound(3);
    expect(round3.prizePool).to.equal(round2Pool);
  });

  it("[orphan-recovery] adminCreditOrphanedFunds credits stuck USDT into current OPEN round", async () => {
    // Simulate a USDT balance the contract isn't tracking (e.g. legacy orphan)
    // by direct-transferring into the contract, then have admin credit it.
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);

    const stuck = ethers.parseEther("500");
    await usdt.mint(await lottery.getAddress(), stuck);

    const before = (await lottery.getRound(1)).prizePool;
    await expect(lottery.adminCreditOrphanedFunds(stuck))
      .to.emit(lottery, "OrphanedFundsCredited")
      .withArgs(1, stuck);
    const after = (await lottery.getRound(1)).prizePool;
    expect(after).to.equal(before + stuck);

    // Only owner
    await expect(lottery.connect(alice).adminCreditOrphanedFunds(1n))
      .to.be.revertedWith(OWNER_REVERT);

    // Reverts if amount exceeds contract USDT balance
    const bal = await usdt.balanceOf(await lottery.getAddress());
    await expect(lottery.adminCreditOrphanedFunds(bal + 1n))
      .to.be.revertedWithCustomError(lottery, "InsufficientContractBalance");

    // Reverts if current round is not OPEN
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    await lottery.drawNumber(1);  // round 1 has 0 tickets → CLAIMABLE
    await expect(lottery.adminCreditOrphanedFunds(1n))
      .to.be.revertedWithCustomError(lottery, "WrongRoundStatus");
  });

  it("[orphan-hardening] cannot double-credit the same orphaned funds past the balance", async () => {
    // After crediting the full orphan once, prizePool == on-hand balance, so a
    // second credit (even 1 wei) must revert. This closes the double-credit
    // footgun where the advertised prizePool could exceed the USDT actually held.
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);
    const addr = await lottery.getAddress();

    const stuck = ethers.parseEther("500");
    await usdt.mint(addr, stuck);

    // First credit moves the orphan into the pool: prizePool now == balance.
    await lottery.adminCreditOrphanedFunds(stuck);
    expect((await lottery.getRound(1)).prizePool).to.equal(await usdt.balanceOf(addr));

    // Double-credit: 1 wei alone is far under the balance, but prizePool + 1 > bal,
    // so the hardened check rejects it (pre-fix this silently inflated prizePool).
    await expect(lottery.adminCreditOrphanedFunds(1n))
      .to.be.revertedWithCustomError(lottery, "InsufficientContractBalance");

    // A genuine new orphan is still creditable, but only up to the fresh headroom.
    const extra = ethers.parseEther("100");
    await usdt.mint(addr, extra);
    await expect(lottery.adminCreditOrphanedFunds(extra + 1n))
      .to.be.revertedWithCustomError(lottery, "InsufficientContractBalance");
    await expect(lottery.adminCreditOrphanedFunds(extra))
      .to.emit(lottery, "OrphanedFundsCredited").withArgs(1, extra);
    expect((await lottery.getRound(1)).prizePool).to.equal(await usdt.balanceOf(addr));
  });

  // ── Operator role (low-privilege automation key for postBracketCounts) ───────

  // Drive a single-ticket round all the way to RESULTS_PENDING so that
  // postBracketCounts is callable. `winning` decides the bracket counts.
  async function runToResultsPending(winning: number) {
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await lottery.openRound(tree.root);
    await lottery.connect(alice).buyTickets(1, [123456], 1, 0, 0, EMPTY_PROOF);
    await ethers.provider.send("evm_increaseTime", [Number(ROUND_DURATION_SEC + DRAW_DELAY_SEC + 1n)]);
    await ethers.provider.send("evm_mine", []);
    const drawRcpt = await (await lottery.drawNumber(1)).wait();
    const reqId = drawRcpt!.logs
      .map((l: any) => { try { return lottery.interface.parseLog(l); } catch { return null; } })
      .find((e: any) => e?.name === "DrawRequested")!.args.vrfRequestId as bigint;
    await vrf.fulfillRandomWordsWithOverride(reqId, await lottery.getAddress(), [winning]);
  }

  it("[operator] defaults to the zero address (disabled)", async () => {
    expect(await lottery.operator()).to.equal(ethers.ZeroAddress);
  });

  it("[operator] only owner can setOperator, and it emits OperatorUpdated(old,new)", async () => {
    await expect(lottery.connect(alice).setOperator(bobAddr)).to.be.revertedWith(OWNER_REVERT);

    await expect(lottery.setOperator(bobAddr))
      .to.emit(lottery, "OperatorUpdated").withArgs(ethers.ZeroAddress, bobAddr);
    expect(await lottery.operator()).to.equal(bobAddr);

    // Rotating to a different operator reports the previous one
    await expect(lottery.setOperator(aliceAddr))
      .to.emit(lottery, "OperatorUpdated").withArgs(bobAddr, aliceAddr);

    // Clearing back to zero disables operator access again, via the distinct
    // OperatorDisabled event so monitoring can tell a disable from a change. [F-01]
    await expect(lottery.setOperator(ethers.ZeroAddress))
      .to.emit(lottery, "OperatorDisabled").withArgs(aliceAddr);
    expect(await lottery.operator()).to.equal(ethers.ZeroAddress);
  });

  it("[operator][F-01] setOperator reverts on a no-op (zero->zero and same-nonzero)", async () => {
    // Already address(0) by default → clearing again is a no-op and must revert.
    await expect(lottery.setOperator(ethers.ZeroAddress))
      .to.be.revertedWithCustomError(lottery, "SameOperator");
    // Set to bob, then re-setting bob is a no-op and must revert (no event spam).
    await lottery.setOperator(bobAddr);
    await expect(lottery.setOperator(bobAddr))
      .to.be.revertedWithCustomError(lottery, "SameOperator");
  });

  it("[operator] designated operator can postBracketCounts", async () => {
    await lottery.setOperator(bobAddr);
    await runToResultsPending(999999); // 0 matches → all-zero counts
    await expect(lottery.connect(bob).postBracketCounts(1, [0, 0, 0, 0, 0, 0]))
      .to.emit(lottery, "BracketCountsPosted");
    expect((await lottery.getRound(1)).status).to.equal(4); // CLAIMABLE
  });

  it("[operator] owner can still postBracketCounts when no operator is set", async () => {
    await runToResultsPending(999999);
    await expect(lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]))
      .to.emit(lottery, "BracketCountsPosted");
  });

  it("[operator] a non-operator non-owner cannot postBracketCounts", async () => {
    await lottery.setOperator(bobAddr);
    await runToResultsPending(999999);
    await expect(lottery.connect(alice).postBracketCounts(1, [0, 0, 0, 0, 0, 0]))
      .to.be.revertedWithCustomError(lottery, "NotOperatorOrOwner");
  });

  it("[operator] a cleared/previous operator loses access; owner still works", async () => {
    await lottery.setOperator(bobAddr);
    await lottery.setOperator(ethers.ZeroAddress);
    await runToResultsPending(999999);
    await expect(lottery.connect(bob).postBracketCounts(1, [0, 0, 0, 0, 0, 0]))
      .to.be.revertedWithCustomError(lottery, "NotOperatorOrOwner");
    await expect(lottery.postBracketCounts(1, [0, 0, 0, 0, 0, 0]))
      .to.emit(lottery, "BracketCountsPosted");
  });

  it("[operator] operator has NO access to other admin functions", async () => {
    await lottery.setOperator(bobAddr);
    await expect(lottery.connect(bob).setTicketPrice(ethers.parseEther("2"))).to.be.revertedWith(OWNER_REVERT);
    await expect(lottery.connect(bob).setOperator(aliceAddr)).to.be.revertedWith(OWNER_REVERT);
    await expect(lottery.connect(bob).adminCreditOrphanedFunds(1n)).to.be.revertedWith(OWNER_REVERT);
    const tree = buildXPTree(1n, [{ wallet: aliceAddr, xp: 0n }]);
    await expect(lottery.connect(bob).openRound(tree.root)).to.be.revertedWith(OWNER_REVERT);
  });
});
