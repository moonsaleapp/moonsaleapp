# MoonsaleLottery.sol — Delta Review Request (post IGH-2026-004)

**Requested:** delta / diff review (not a full re-audit) of the changes made to
`MoonsaleLottery.sol` since your final sign-off **IGH-2026-004 (2026-05-29, 91/100)**.

Per the IGH-2026-004 disclaimer ("No further audit round is required unless
additional code changes are made"), we have since made additional code changes
and are requesting review of only those.

## What to review

Three commits since the audited baseline. Total surface: **+90 / -4 lines**.
See the attached `MoonsaleLottery-delta-since-IGH-2026-004.diff` for the exact
diff; the full current file is attached as `MoonsaleLottery.sol` (877 lines).

1. **Operator role (least-privilege automation key)**
   - New `address public operator` + `setOperator(address) onlyOwner` + `OperatorUpdated(old,new)` event + `NotOperatorOrOwner` error + `onlyOperatorOrOwner` modifier (`msg.sender == operator || owner()`).
   - **`postBracketCounts` privilege relaxed from `onlyOwner` to `onlyOperatorOrOwner`.** This is the one new privilege boundary on a payout-affecting function. Motivation: the always-on backend cron now holds a low-privilege hot key that can ONLY post bracket counts; the owner key is no longer on the server.
   - Everything else stays `onlyOwner`; `drawNumber` stays permissionless.

2. **Zero-buyer orphan-rollover fix** (`drawNumber` zero-ticket branch)
   - Parks the full `prizePool` into `bracketAmounts[5]` so the existing
     `openRound` rollover loop carries it to the next round. Previously a
     zero-buyer round's pool was orphaned on the contract balance. (This edge
     case was not covered by the IGH-2026-001..004 suite.)

3. **`adminCreditOrphanedFunds(uint256)` + hardening**
   - New `onlyOwner` recovery function: credits orphaned USDT on the contract
     balance into the current OPEN round's `prizePool`.
   - Hardened bound: reverts when **`r.prizePool + amount > balanceOf(this)`**
     (not merely `amount > balance`), so the advertised prizePool can never
     exceed USDT on hand and the same orphan cannot be double-credited.

## Specific questions for the reviewer

1. **`onlyOperatorOrOwner` correctness** — is the modifier logic sound, and is
   `postBracketCounts` the only function whose access was widened?
2. **`setOperator`** — owner-only, event emitted, no zero-address footgun
   (we intentionally allow `address(0)` to *disable* the operator).
3. **Operator threat model** — can a compromised OPERATOR key, by posting
   incorrect `counts[6]`, misdirect or lock funds beyond distorting the CURRENT
   round's bracket split? (The original audit treated this path as owner-trusted.)
   Confirm it cannot touch params, treasury, fund recovery, or other rounds.
4. **`adminCreditOrphanedFunds`** — is the `prizePool + amount > balance` bound
   sufficient, or should it also subtract unclaimed amounts owed to past
   CLAIMABLE rounds? (We treat that as admin off-chain responsibility today; the
   per-round unclaimed loop would be unbounded.)
5. **Orphan-rollover** — parking into `bracketAmounts[5]` interacts correctly
   with the `openRound` rollover loop and does not double-count treasury.

## Out of scope

All other 2026-05-30 work is **off-chain** (frontend, cron, DB, key handling) and
has no bearing on contract bytecode. No constructor, VRF, claim-math, or
reward-distribution logic changed.

## Test coverage

`contracts/test/MoonsaleLottery.test.ts` — 25 passing, including new cases:
`[operator] *` (6 cases covering access boundaries) and `[orphan-hardening]`
(double-credit rejection) + `[orphan-rollover]` / `[orphan-recovery]`.

## Attachments
- `MoonsaleLottery.sol` — full current source (877 lines)
- `MoonsaleLottery-delta-since-IGH-2026-004.diff` — the +90/-4 delta
