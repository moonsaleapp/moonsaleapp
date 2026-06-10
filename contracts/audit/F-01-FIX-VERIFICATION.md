# MoonsaleLottery.sol — F-01 Fix Verification Request (closeout for IGH-2026-005)

**Requested:** confirmation that **F-01 (Low)** from IGH-2026-005 is resolved, and the
corresponding score update. This is a fix-verification of a single ~15-line change that
implements your own F-01 recommendation verbatim — not a new audit round.

## What F-01 asked for
> *"guard against the no-op repeated-zero case: `if (newOperator == operator) revert();`"*
> *"optionally add a dedicated `OperatorDisabled(address indexed previousOperator)` event
> emitted when `newOperator == address(0)` instead of the general `OperatorUpdated` event."*

## What we implemented
Both recommendations, in `setOperator` (see attached `F-01-fix-since-IGH-2026-005.diff`):
1. **No-op guard:** `if (newOperator == operator) revert SameOperator();` — rejects
   redundant sets (including zero->zero), so the event log is a reliable changelog.
2. **Distinct disable event:** when `newOperator == address(0)`, emit
   `OperatorDisabled(operator)` instead of `OperatorUpdated`, giving monitoring an
   unambiguous disable signal.
3. New `error SameOperator()` and `event OperatorDisabled(address indexed previousOperator)`
   following the contract's existing naming/indexing conventions.

## What did NOT change
No access-control logic changed. `onlyOperatorOrOwner`, `postBracketCounts`, the operator
privilege boundary, and every other function are byte-for-byte the same as the
IGH-2026-005-reviewed source. This change only affects `setOperator`'s event emission and
adds a no-op revert.

## Test coverage
New test `[operator][F-01] setOperator reverts on a no-op (zero->zero and same-nonzero)`;
the existing operator test now asserts `OperatorDisabled` on clear. Full suite: **26 passing**.

## Notes on the other IGH-2026-005 items
- **F-02 (Info, accepted as design):** unchanged. We will run the off-chain orphan-balance
  computation before any `adminCreditOrphanedFunds` use in production, as recommended.
- **E-01:** already corrected in source (`ABSOLUTE_MIN_ROUND_DURATION = 5 minutes`,
  comments updated, tagged `[E-01]`); it was carried forward as Open only because it sits
  in code outside the IGH-2026-005 delta scope.
- **Multisig:** owner + treasury will be a Gnosis Safe at mainnet deploy (operational).

## Deployed artifact (for bytecode-vs-source verification)
The F-01-inclusive source is deployed and **BscScan-verified on BSC Testnet**, so you can
confirm the deployed bytecode matches the reviewed source:
- **Testnet:** `0x73FFb254345fB5bb22D4fD70237B45b45a4349AE`
  https://testnet.bscscan.com/address/0x73FFb254345fB5bb22D4fD70237B45b45a4349AE#code
- **Mainnet:** a separate address (Gnosis Safe owner + treasury, fresh dedicated operator
  key, real USDT) will be deployed and sent for a final bytecode-match + sign-off.

## Attachments
- `F-01-fix-since-IGH-2026-005.diff` — the +15/-3 setOperator change
- (full current `MoonsaleLottery.sol` available on request)

## Requested
Please issue a short addendum to IGH-2026-005 (or IGH-2026-006) marking **F-01 → Resolved**
and stating the revised score. We understand the full 91+ sign-off is contingent on the
multisig, which is deployed at the mainnet step — at which point we'll submit the mainnet
address for the final bytecode-match confirmation.
