// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title MoonsaleLottery
 * @notice PancakeSwap v2-style 6-digit lottery. Each ticket holds a 6-digit
 *         number (000000-999999). VRF picks the winning number. Tickets are
 *         scored by their longest left-to-right prefix match with the winning
 *         number. Prize pool is split across 6 brackets (Match-1 through
 *         Match-6 / Jackpot) plus a fixed treasury cut. Bracket exclusivity:
 *         a ticket counts only in its highest bracket.
 *
 *         Reward distribution defaults (basis points, must sum to 10000):
 *           Match-1: 100   (1%)
 *           Match-2: 300   (3%)
 *           Match-3: 500   (5%)
 *           Match-4: 1000  (10%)
 *           Match-5: 2500  (25%)
 *           Match-6: 5500  (55%, Jackpot)
 *           Treasury: 100  (1%)
 *
 *         Empty brackets (zero matching tickets) roll into the next round's
 *         prize pool when openRound is called.
 *
 *         XP integration via Merkle proof at round open (off-chain snapshot).
 *         Bonus tickets from XP burn (default 10 XP = 1 bonus ticket).
 */
contract MoonsaleLottery is Pausable, ReentrancyGuard, VRFConsumerBaseV2Plus {
    using SafeERC20 for IERC20;

    // ── Types ──────────────────────────────────────────────────────────────────

    enum RoundStatus {
        NONE,             // not initialized
        OPEN,             // accepting buys
        DRAWING,          // drawNumber called, awaiting VRF
        RESULTS_PENDING,  // VRF returned, awaiting admin postBracketCounts
        CLAIMABLE         // results posted, treasury paid, claims open
    }

    /// @dev One ticket = one storage slot (packed). `number` is the 6-digit
    ///      number (0-999999); `claimed` flips on successful claim. Sentinel
    ///      `type(uint32).max` passed by buyer means "quick pick" — contract
    ///      derives the number deterministically from (roundId, ticketIndex).
    struct Ticket {
        address owner;   // 20 bytes
        uint32  number;  // 4 bytes (0..999999 after normalization)
        bool    claimed; // 1 byte
        // 7 bytes padding — fits in 1 slot
    }

    struct Round {
        bytes32 xpMerkleRoot;
        uint64  startTime;
        uint64  endTime;
        uint256 vrfRequestId;           // [L-02] full uint256 (was uint128, truncating from VRF)
        uint256 prizePool;
        uint32  totalTickets;
        uint32  winningNumber;          // 0..999999, valid only after VRF returns
        uint256 treasuryAmount;         // snapshotted at postBracketCounts
        RoundStatus status;
        uint32[6]  bracketCounts;       // [0]=Match-1 .. [5]=Match-6 (Jackpot)
        uint256[6] bracketAmounts;      // snapshotted USDT per bracket
        uint32[6]  bracketClaimsCount;  // [L-01] how many claims processed per bracket
        uint256[6] bracketPaid;         // [L-01] cumulative USDT paid out per bracket
    }

    // ── Constants ──────────────────────────────────────────────────────────────

    uint256 public constant MIN_TICKET_PRICE = 0.1e18;
    uint256 public constant MAX_TICKET_PRICE = 100e18;
    uint256 public constant MAX_TICKETS_PER_BUY = 100;
    /// @notice [I-03] Hard cap on `claimBatch` array size to keep a single call well
    ///         under the per-tx block gas limit.
    uint256 public constant MAX_CLAIM_BATCH     = 200;
    uint32  public constant QUICK_PICK_SENTINEL = type(uint32).max;
    uint32  public constant NUMBER_MODULO       = 1_000_000;

    /// @notice [M-02] Hard bounds on admin-tunable timing setters. Prevents a
    ///         compromised owner key from freezing the lottery (`roundDuration`
    ///         too large) or front-running buyers (`drawDelay` too short).
    ///
    /// [admin-min-round / D-01] The lower bound for `roundDuration` is
    ///         admin-tunable via `setMinRoundDuration()`. The absolute floor
    ///         is `constant` and unbreakable; per auditor D-01 it is set to
    ///         5 minutes for mainnet realism (a 30-second BSC round is
    ///         unplayable). `setMinRoundDuration` also requires
    ///         `newMin <= roundDuration` so the floor can never be raised
    ///         above the currently-configured duration, eliminating the
    ///         operational footgun where a stale `roundDuration` could silently
    ///         violate a freshly-raised floor on the next openRound.
    uint256 public constant ABSOLUTE_MIN_ROUND_DURATION = 5 minutes;
    uint256 public constant MAX_ROUND_DURATION         = 30 days;
    uint256 public constant MAX_DRAW_DELAY             = 6 hours;
    uint32  public constant VRF_CALLBACK_GAS_LIMIT = 200_000;
    uint16  public constant VRF_REQUEST_CONFIRMATIONS = 3;

    /// @notice Time after endTime+drawDelay that must pass before an admin can
    ///         reset a stuck DRAWING round back to OPEN. Protects against VRF
    ///         failures (wrong key hash, dead subscription, dropped request).
    uint256 public constant STUCK_DRAW_TIMEOUT = 1 hours;

    uint256 public constant SPONSOR_BRONZE_AMOUNT = 200e18;
    uint256 public constant SPONSOR_SILVER_AMOUNT = 500e18;
    uint256 public constant SPONSOR_GOLD_AMOUNT   = 1000e18;

    // ── Immutable config ───────────────────────────────────────────────────────

    IERC20  public immutable usdt;
    uint256 public immutable vrfSubscriptionId;
    bytes32 public immutable vrfKeyHash;

    // ── Admin-tunable config ───────────────────────────────────────────────────

    uint256 public ticketPrice;
    uint256 public xpBurnRate;
    uint256 public roundDuration;
    uint256 public drawDelay;
    /// @notice [admin-min-round] Mutable floor for `roundDuration`, bounded by
    ///         `[ABSOLUTE_MIN_ROUND_DURATION, MAX_ROUND_DURATION]`.
    uint256 public minRoundDuration;

    /// @notice Reward distribution in basis points. Indices: 0=Match-1 .. 5=Match-6.
    ///         Sum of these + treasuryPercent MUST equal 10000.
    uint16[6] public bracketPercents;
    uint16    public treasuryPercent;
    address   public treasuryWallet;

    /// @notice Low-privilege operator allowed to call automation-only functions
    ///         (currently only `postBracketCounts`). Set by owner via
    ///         `setOperator`. This lets the always-on backend cron hold a hot key
    ///         that can post bracket results without holding full owner powers —
    ///         params, treasury, fund recovery, and round opening all remain
    ///         `onlyOwner`. A leaked operator key can at worst distort the current
    ///         round's bracket payout split; it cannot touch config, treasury, or
    ///         other rounds. Defaults to address(0) (disabled) until owner sets it.
    address   public operator;

    // ── Round state ────────────────────────────────────────────────────────────

    uint256 public currentRoundId;
    mapping(uint256 roundId => Round) public rounds;
    mapping(uint256 roundId => Ticket[]) private _tickets;
    mapping(uint256 roundId => mapping(address => uint256)) public xpBurnedThisRound;
    mapping(uint256 vrfRequestId => uint256 roundId) private _vrfRequestToRound;

    // ── Events ─────────────────────────────────────────────────────────────────

    event RoundOpened(
        uint256 indexed roundId,
        bytes32 xpMerkleRoot,
        uint256 startTime,
        uint256 endTime,
        uint256 prizePoolFromRollover
    );

    event TicketsBought(
        uint256 indexed roundId,
        address indexed buyer,
        uint32  usdtTickets,
        uint32  bonusTickets,
        uint256 xpBurned,
        uint256 usdtPaid,
        uint32  firstTicketIndex
    );

    event XPBurned(uint256 indexed roundId, address indexed wallet, uint256 amount);

    event SponsorDeposited(
        uint256 indexed roundId,
        address indexed sponsor,
        uint8 packageType,
        uint256 amount
    );

    event DrawRequested(uint256 indexed roundId, uint256 vrfRequestId);
    event WinningNumberDrawn(uint256 indexed roundId, uint32 winningNumber);

    event BracketCountsPosted(
        uint256 indexed roundId,
        uint32 winningNumber,
        uint32[6] counts,
        uint256[6] amounts,
        uint256 treasuryAmount
    );

    event Claimed(
        uint256 indexed roundId,
        address indexed wallet,
        uint256 ticketIndex,
        uint8 bracket,
        uint256 amount
    );

    event NoBuyersRollover(uint256 indexed roundId, uint256 prizePoolToRollover);
    event EmptyBracketRolledOver(uint256 indexed fromRound, uint256 indexed toRound, uint256 totalAmount);

    /// @notice Admin credited orphaned USDT (sitting on the contract balance with no
    ///         round binding) into the current OPEN round's prizePool. Used to recover
    ///         from edge cases such as a zero-buyer round whose pool wasn't rolled
    ///         over by an earlier contract version, or any direct USDT transfer to
    ///         the contract that the protocol couldn't otherwise account for.
    event OrphanedFundsCredited(uint256 indexed roundId, uint256 amount);

    event TicketPriceUpdated(uint256 oldPrice, uint256 newPrice);
    event XPBurnRateUpdated(uint256 oldRate, uint256 newRate);
    event RoundDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event MinRoundDurationUpdated(uint256 oldMin, uint256 newMin);
    event DrawDelayUpdated(uint256 oldDelay, uint256 newDelay);
    /// @notice [I-05] Includes oldTreasuryWallet so an off-chain monitor can
    ///         reconstruct the rotation history from events alone.
    event RewardDistributionUpdated(
        uint16[6] bracketPercents,
        uint16 treasuryPercent,
        address indexed oldTreasuryWallet,
        address indexed newTreasuryWallet
    );

    /// @notice Emitted when admin resets a DRAWING round back to OPEN after the
    ///         stuck-draw timeout has elapsed. Indicates a VRF failure was
    ///         observed off-chain and the operator is forcing a retry.
    event StuckDrawReset(uint256 indexed roundId, uint256 abandonedVrfRequestId, uint64 newEndTime);

    /// @notice Emitted when owner sets or changes the operator to a non-zero address.
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    /// @notice Emitted when owner deliberately disables the operator (sets it to
    ///         address(0)). A distinct event from OperatorUpdated so off-chain
    ///         monitoring can unambiguously tell a disable apart from a normal
    ///         operator change. [F-01]
    event OperatorDisabled(address indexed previousOperator);

    // ── Errors ─────────────────────────────────────────────────────────────────

    error NoOpenRound();
    error RoundNotOpen();
    error RoundAlreadyOpen();
    error RoundNotReadyForDraw();
    error WrongRoundStatus();
    error InvalidMerkleProof();
    error InvalidXpBurn(uint256 requested, uint256 allowed);
    error ZeroUsdtTickets();
    error TooManyTickets(uint256 requested, uint256 max);
    error NumbersLengthMismatch(uint256 expected, uint256 got);
    error InvalidTicketPrice();
    error InvalidBurnRate();
    error InvalidSponsorPackage();
    error PreviousRoundNotComplete(uint256 roundId);
    error VrfRequestUnknown();
    error PercentSumNot100(uint256 actual);
    error InvalidTreasuryWallet();
    error TicketAlreadyClaimed();
    error TicketHasNoWinningMatch();
    error NotTicketOwner();
    error StuckDrawTimeoutNotElapsed(uint256 readyAt);
    error InvalidUsdtAddress();             // [I-01]
    error InvalidDuration();                // [M-02]
    error InvalidDelay();                   // [M-02]
    error EndTimeOverflow();                // [M-02]
    error NoActiveRound();                  // adminCreditOrphanedFunds
    error InsufficientContractBalance();    // adminCreditOrphanedFunds
    error NotOperatorOrOwner();             // onlyOperatorOrOwner modifier
    error SameOperator();                   // setOperator no-op guard [F-01]

    // ── Constructor ────────────────────────────────────────────────────────────

    constructor(
        address _usdt,
        address _vrfCoordinator,
        uint256 _vrfSubscriptionId,
        bytes32 _vrfKeyHash,
        address _treasuryWallet
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        if (_usdt == address(0)) revert InvalidUsdtAddress();         // [I-01]
        if (_treasuryWallet == address(0)) revert InvalidTreasuryWallet();
        usdt = IERC20(_usdt);
        vrfSubscriptionId = _vrfSubscriptionId;
        vrfKeyHash = _vrfKeyHash;
        treasuryWallet = _treasuryWallet;

        ticketPrice      = 1e18;
        xpBurnRate       = 10;
        roundDuration    = 10 minutes;
        drawDelay        = 1 minutes;
        // [D-01 / admin-min-round] Default matches ABSOLUTE_MIN_ROUND_DURATION
        // (5 min). Admin can raise via setMinRoundDuration up to MAX_ROUND_DURATION,
        // but never lower than the absolute floor.
        minRoundDuration = ABSOLUTE_MIN_ROUND_DURATION;

        // Default reward split: 1/3/5/10/25/55 brackets, 1 treasury = 100
        bracketPercents = [uint16(100), 300, 500, 1000, 2500, 5500];
        treasuryPercent = 100;
    }

    // ── Modifiers ──────────────────────────────────────────────────────────────

    /// @notice Restricts to the owner OR the designated operator. The owner
    ///         always retains access; the operator is the optional low-privilege
    ///         automation hot key. Reverts for everyone else.
    modifier onlyOperatorOrOwner() {
        if (msg.sender != operator && msg.sender != owner()) revert NotOperatorOrOwner();
        _;
    }

    // ── Admin: round lifecycle ─────────────────────────────────────────────────

    /**
     * @notice Open a new round. Previous round must be CLAIMABLE (or 0). Any
     *         empty bracket pools from the previous round roll into the new
     *         round's prize pool.
     */
    function openRound(bytes32 xpMerkleRoot) external onlyOwner whenNotPaused {
        uint256 prevRoundId = currentRoundId;
        uint256 rolledOver = 0;

        if (prevRoundId != 0) {
            Round storage prev = rounds[prevRoundId];

            // Allow opening if prev is OPEN/DRAWING but had zero tickets and is past endTime.
            if (prev.status == RoundStatus.OPEN || prev.status == RoundStatus.DRAWING) {
                if (prev.totalTickets == 0 && block.timestamp >= prev.endTime) {
                    rolledOver = prev.prizePool;
                    prev.prizePool = 0;
                    prev.status = RoundStatus.CLAIMABLE; // mark settled
                    emit NoBuyersRollover(prevRoundId, rolledOver);
                } else {
                    revert PreviousRoundNotComplete(prevRoundId);
                }
            } else if (prev.status == RoundStatus.CLAIMABLE) {
                // Roll over any empty bracket pools (count == 0 but amount > 0)
                uint256 emptySum;
                for (uint8 i = 0; i < 6; i++) {
                    if (prev.bracketCounts[i] == 0 && prev.bracketAmounts[i] > 0) {
                        emptySum += prev.bracketAmounts[i];
                        prev.bracketAmounts[i] = 0;
                    }
                }
                if (emptySum > 0) {
                    rolledOver += emptySum;
                    emit EmptyBracketRolledOver(prevRoundId, prevRoundId + 1, emptySum);
                }
            } else if (prev.status == RoundStatus.RESULTS_PENDING) {
                // VRF returned but bracket counts not yet posted — block
                revert PreviousRoundNotComplete(prevRoundId);
            }
            // NONE shouldn't happen for prevRoundId != 0, but safe fallthrough
        }

        uint256 newRoundId = prevRoundId + 1;
        // [M-02] Guard the uint64 cast so a malformed roundDuration cannot wrap
        // endTime into the past and unlock premature draws.
        uint256 endTs = block.timestamp + roundDuration;
        if (endTs > type(uint64).max) revert EndTimeOverflow();
        Round storage r = rounds[newRoundId];
        r.xpMerkleRoot = xpMerkleRoot;
        r.startTime    = uint64(block.timestamp);
        r.endTime      = uint64(endTs);
        r.prizePool    = rolledOver;
        r.status       = RoundStatus.OPEN;
        currentRoundId = newRoundId;

        emit RoundOpened(newRoundId, xpMerkleRoot, r.startTime, r.endTime, rolledOver);
    }

    // ── User: buy tickets ──────────────────────────────────────────────────────

    /**
     * @notice Buy tickets with 6-digit numbers.
     * @param  roundId      Must equal currentRoundId.
     * @param  numbers      Array of 6-digit numbers (0..999999) OR QUICK_PICK_SENTINEL
     *                      for auto-fill. Length MUST equal usdtTickets + bonusTickets.
     * @param  usdtTickets  Number of paid tickets (>= 1).
     * @param  xpToBurn     XP to burn for bonus tickets (0 if none).
     * @param  xpSnapshot   Caller's XP at round-open from Merkle leaf.
     * @param  merkleProof  Proof against round.xpMerkleRoot.
     */
    function buyTickets(
        uint256 roundId,
        uint32[] calldata numbers,
        uint256 usdtTickets,
        uint256 xpToBurn,
        uint256 xpSnapshot,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        if (usdtTickets == 0) revert ZeroUsdtTickets();
        if (roundId != currentRoundId) revert RoundNotOpen();

        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.OPEN) revert RoundNotOpen();
        if (block.timestamp >= r.endTime) revert RoundNotOpen();

        // XP burn check
        if (xpToBurn > 0) {
            if (xpSnapshot == 0) revert InvalidXpBurn(xpToBurn, 0);

            // [M-03] Include roundId in the leaf so a proof valid for round N
            // cannot be replayed in round N+1 even if the admin re-uses the same
            // Merkle root (e.g. the off-chain rotation step fails).
            bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(roundId, msg.sender, xpSnapshot))));
            if (!MerkleProof.verify(merkleProof, r.xpMerkleRoot, leaf)) revert InvalidMerkleProof();

            uint256 maxBurnByPurchase = usdtTickets * xpBurnRate;
            if (xpToBurn > maxBurnByPurchase) revert InvalidXpBurn(xpToBurn, maxBurnByPurchase);

            uint256 alreadyBurned = xpBurnedThisRound[roundId][msg.sender];
            if (alreadyBurned + xpToBurn > xpSnapshot) revert InvalidXpBurn(xpToBurn, xpSnapshot - alreadyBurned);

            xpBurnedThisRound[roundId][msg.sender] = alreadyBurned + xpToBurn;
            emit XPBurned(roundId, msg.sender, xpToBurn);
        }

        uint256 bonusTickets = xpToBurn / xpBurnRate;
        uint256 total = usdtTickets + bonusTickets;
        if (total > MAX_TICKETS_PER_BUY) revert TooManyTickets(total, MAX_TICKETS_PER_BUY);
        if (numbers.length != total) revert NumbersLengthMismatch(total, numbers.length);

        // Push tickets
        Ticket[] storage roundTickets = _tickets[roundId];
        uint32 firstIndex = r.totalTickets;
        for (uint256 i = 0; i < total; i++) {
            uint32 num = numbers[i];
            if (num == QUICK_PICK_SENTINEL) {
                num = uint32(uint256(keccak256(abi.encodePacked(
                    address(this), roundId, firstIndex + i, block.prevrandao
                ))) % NUMBER_MODULO);
            } else {
                num = num % NUMBER_MODULO; // normalize
            }
            roundTickets.push(Ticket({ owner: msg.sender, number: num, claimed: false }));
        }
        r.totalTickets = firstIndex + uint32(total);

        // Pull USDT
        uint256 usdtCost = usdtTickets * ticketPrice;
        r.prizePool += usdtCost;
        usdt.safeTransferFrom(msg.sender, address(this), usdtCost);

        emit TicketsBought(roundId, msg.sender, uint32(usdtTickets), uint32(bonusTickets), xpToBurn, usdtCost, firstIndex);
    }

    // ── User: sponsor ──────────────────────────────────────────────────────────

    // [I-02] sponsorDeposit now takes an explicit roundId so a sponsor's tx
    //        can't accidentally land in the next round if confirmation slips
    //        across the OPEN→DRAWING boundary.
    function sponsorDeposit(uint256 roundId, uint8 packageType) external nonReentrant whenNotPaused {
        uint256 amount;
        if      (packageType == 1) amount = SPONSOR_BRONZE_AMOUNT;
        else if (packageType == 2) amount = SPONSOR_SILVER_AMOUNT;
        else if (packageType == 3) amount = SPONSOR_GOLD_AMOUNT;
        else revert InvalidSponsorPackage();

        if (roundId == 0 || roundId != currentRoundId) revert NoOpenRound();

        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.OPEN) revert RoundNotOpen();

        r.prizePool += amount;
        usdt.safeTransferFrom(msg.sender, address(this), amount);

        emit SponsorDeposited(roundId, msg.sender, packageType, amount);
    }

    // ── Permissionless: trigger VRF ────────────────────────────────────────────

    /**
     * @notice Anyone can call once endTime + drawDelay has passed. No keeper
     *         reward — cron handles this in normal flow.
     */
    function drawNumber(uint256 roundId) external nonReentrant whenNotPaused {
        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.OPEN) revert RoundNotReadyForDraw();
        if (block.timestamp < uint256(r.endTime) + drawDelay) revert RoundNotReadyForDraw();

        // Zero-ticket round → just settle for rollover on next openRound.
        //
        // [orphan-rollover fix] Park the entire prizePool into bracketAmounts[5]
        // so the existing CLAIMABLE-branch rollover loop in openRound picks it up.
        // Without this, the pool was bound only to `r.prizePool` and the rollover
        // loop (which only inspects `bracketAmounts[]`) would miss it entirely —
        // orphaning the funds on the contract balance. bracketCounts[5] stays 0,
        // treasuryAmount stays 0 (no buyers, no treasury cut).
        if (r.totalTickets == 0) {
            r.bracketAmounts[5] = r.prizePool;
            r.status = RoundStatus.CLAIMABLE; // empty: nothing to claim, full pool rolls
            emit NoBuyersRollover(roundId, r.prizePool);
            return;
        }

        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash:              vrfKeyHash,
                subId:                vrfSubscriptionId,
                requestConfirmations: VRF_REQUEST_CONFIRMATIONS,
                callbackGasLimit:     VRF_CALLBACK_GAS_LIMIT,
                numWords:             1,
                extraArgs:            VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({ nativePayment: false })
                )
            })
        );

        // [L-02] Store the full uint256 — earlier versions truncated to uint128.
        r.vrfRequestId = requestId;
        r.status       = RoundStatus.DRAWING;
        _vrfRequestToRound[requestId] = roundId;

        emit DrawRequested(roundId, requestId);
    }

    /**
     * @dev VRF callback. Stores the winning number; bracket counts must be
     *      posted by admin via postBracketCounts before claims can start.
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 roundId = _vrfRequestToRound[requestId];
        if (roundId == 0) revert VrfRequestUnknown();

        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.DRAWING) return; // idempotent

        uint32 winning = uint32(randomWords[0] % NUMBER_MODULO);
        r.winningNumber = winning;
        r.status        = RoundStatus.RESULTS_PENDING;

        // [L-03] Free the orphaned mapping entry now that the request is settled.
        delete _vrfRequestToRound[requestId];

        emit WinningNumberDrawn(roundId, winning);
    }

    // ── Admin: post bracket counts ─────────────────────────────────────────────

    /**
     * @notice Owner or operator posts the off-chain-computed counts of winning
     *         tickets per bracket. Snapshots per-bracket USDT amounts from current
     *         bracketPercents/treasuryPercent and transfers treasury cut.
     *         Round becomes CLAIMABLE.
     * @param  counts  [Match-1, Match-2, Match-3, Match-4, Match-5, Match-6]
     */
    function postBracketCounts(uint256 roundId, uint32[6] calldata counts) external onlyOperatorOrOwner {
        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.RESULTS_PENDING) revert WrongRoundStatus();

        uint256 pool = r.prizePool;
        uint256 treasuryCut = (pool * treasuryPercent) / 10_000;

        // [M-01] Compute bracket amounts and accumulate; the residual from integer
        // truncation (up to 7 wei) gets swept into the Jackpot bracket so every
        // wei of prizePool is accounted for. Guarantees the invariant that
        // `sum(bracketAmounts) + treasuryAmount == prizePool`.
        uint256 sumBrackets = 0;
        for (uint8 i = 0; i < 6; i++) {
            r.bracketCounts[i]  = counts[i];
            uint256 amt = (pool * bracketPercents[i]) / 10_000;
            r.bracketAmounts[i] = amt;
            sumBrackets += amt;
        }
        uint256 residual = pool - sumBrackets - treasuryCut;
        if (residual > 0) {
            r.bracketAmounts[5] += residual;  // Jackpot absorbs the dust
        }

        r.treasuryAmount = treasuryCut;
        r.status         = RoundStatus.CLAIMABLE;

        if (treasuryCut > 0) usdt.safeTransfer(treasuryWallet, treasuryCut);

        emit BracketCountsPosted(roundId, r.winningNumber, counts, r.bracketAmounts, treasuryCut);
    }

    // ── User: claim ────────────────────────────────────────────────────────────

    /**
     * @notice Claim a single winning ticket. Ticket is matched on-chain
     *         (left-to-right prefix) against the winning number. Must match
     *         at least 2 digits and be in a non-empty bracket.
     */
    function claim(uint256 roundId, uint256 ticketIndex) external nonReentrant {
        _claim(roundId, ticketIndex);
    }

    /**
     * @notice Claim many tickets in one tx. [I-03] capped at MAX_CLAIM_BATCH.
     */
    function claimBatch(uint256 roundId, uint256[] calldata ticketIndices) external nonReentrant {
        if (ticketIndices.length > MAX_CLAIM_BATCH) {
            revert TooManyTickets(ticketIndices.length, MAX_CLAIM_BATCH);
        }
        for (uint256 i = 0; i < ticketIndices.length; i++) {
            _claim(roundId, ticketIndices[i]);
        }
    }

    function _claim(uint256 roundId, uint256 ticketIndex) internal {
        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.CLAIMABLE) revert WrongRoundStatus();

        Ticket storage t = _tickets[roundId][ticketIndex];
        if (t.owner != msg.sender) revert NotTicketOwner();
        if (t.claimed) revert TicketAlreadyClaimed();

        uint8 matched = _matchedDigits(r.winningNumber, t.number);
        if (matched < 1) revert TicketHasNoWinningMatch();

        uint8 bracket = matched - 1; // 1→0, 2→1, 3→2, 4→3, 5→4, 6→5
        uint32 count = r.bracketCounts[bracket];
        if (count == 0) revert TicketHasNoWinningMatch(); // shouldn't happen if counts posted correctly

        // [L-01] When the last winning ticket in this bracket claims, sweep any
        // rounding residual (bracketAmounts/count integer-division dust) into
        // the final payout so no wei stays stranded.
        uint256 share;
        uint32 alreadyClaimed = r.bracketClaimsCount[bracket];
        if (alreadyClaimed + 1 == count) {
            share = r.bracketAmounts[bracket] - r.bracketPaid[bracket];
        } else {
            share = r.bracketAmounts[bracket] / count;
        }
        r.bracketClaimsCount[bracket] = alreadyClaimed + 1;
        r.bracketPaid[bracket]       += share;

        t.claimed = true;
        usdt.safeTransfer(msg.sender, share);

        emit Claimed(roundId, msg.sender, ticketIndex, bracket, share);
    }

    /**
     * @notice Compute how many leading digits of `ticket` match `winning`.
     *         Both numbers are treated as 6-digit zero-padded strings.
     *         Match is left-to-right: stop at first mismatch.
     */
    function _matchedDigits(uint32 winning, uint32 ticket) internal pure returns (uint8) {
        // Decompose into 6 digits, most-significant first
        uint32 divisor = 100_000; // 10^5
        uint8 matched = 0;
        for (uint8 i = 0; i < 6; i++) {
            uint32 wd = (winning / divisor) % 10;
            uint32 td = (ticket / divisor) % 10;
            if (wd == td) matched++;
            else break;
            divisor /= 10;
        }
        return matched;
    }

    // ── Admin: tunable params ──────────────────────────────────────────────────

    /// @notice Set (or clear) the operator address. Pass address(0) to deliberately
    ///         DISABLE operator access entirely so that only the owner can post
    ///         brackets; this emits OperatorDisabled rather than OperatorUpdated.
    /// @dev    The operator may ONLY call `postBracketCounts`; every other admin
    ///         function remains owner-only. Intended for the backend automation
    ///         hot key. [F-01] Reverts on a no-op (newOperator == current operator)
    ///         so the event log is a reliable changelog and zero->zero spam is
    ///         impossible.
    function setOperator(address newOperator) external onlyOwner {
        if (newOperator == operator) revert SameOperator();
        if (newOperator == address(0)) {
            emit OperatorDisabled(operator);
        } else {
            emit OperatorUpdated(operator, newOperator);
        }
        operator = newOperator;
    }

    function setTicketPrice(uint256 newPrice) external onlyOwner {
        if (newPrice < MIN_TICKET_PRICE || newPrice > MAX_TICKET_PRICE) revert InvalidTicketPrice();
        emit TicketPriceUpdated(ticketPrice, newPrice);
        ticketPrice = newPrice;
    }

    function setXpBurnRate(uint256 newRate) external onlyOwner {
        if (newRate == 0) revert InvalidBurnRate();
        emit XPBurnRateUpdated(xpBurnRate, newRate);
        xpBurnRate = newRate;
    }

    function setRoundDuration(uint256 newDuration) external onlyOwner {
        // [M-02] Hard range guard, prevents owner-key compromise from freezing
        // the lottery (newDuration too large) or releasing wraparound endTime.
        // [admin-min-round] Floor is now mutable via setMinRoundDuration() but
        // can never go below ABSOLUTE_MIN_ROUND_DURATION (5 min, constant). [E-01]
        if (newDuration < minRoundDuration || newDuration > MAX_ROUND_DURATION) revert InvalidDuration();
        emit RoundDurationUpdated(roundDuration, newDuration);
        roundDuration = newDuration;
    }

    /// @notice [admin-min-round] Adjust the lower bound for `roundDuration`. Only
    ///         affects future `setRoundDuration` calls; the current round's
    ///         endTime was already locked at openRound and is unaffected.
    /// @dev    Bounded by `[ABSOLUTE_MIN_ROUND_DURATION, MAX_ROUND_DURATION]`. The
    ///         absolute floor is `constant` and cannot be bypassed.
    ///
    /// [D-01]  Additionally rejects `newMin > roundDuration`. This eliminates
    ///         the operational footgun where a stale `roundDuration` could
    ///         silently violate a freshly-raised floor on the next openRound.
    ///         To raise both, call `setRoundDuration` first, then this setter.
    function setMinRoundDuration(uint256 newMin) external onlyOwner {
        if (newMin < ABSOLUTE_MIN_ROUND_DURATION || newMin > MAX_ROUND_DURATION) revert InvalidDuration();
        if (newMin > roundDuration) revert InvalidDuration();
        emit MinRoundDurationUpdated(minRoundDuration, newMin);
        minRoundDuration = newMin;
    }

    function setDrawDelay(uint256 newDelay) external onlyOwner {
        // [M-02] Upper bound only, zero delay is acceptable (keeper just races VRF).
        if (newDelay > MAX_DRAW_DELAY) revert InvalidDelay();
        emit DrawDelayUpdated(drawDelay, newDelay);
        drawDelay = newDelay;
    }

    /**
     * @notice Set the 5 bracket percents + treasury percent + treasury wallet.
     *         All in basis points. Sum of (5 brackets + treasury) MUST == 10000.
     */
    function setRewardDistribution(
        uint16[6] calldata newBracketPercents,
        uint16 newTreasuryPercent,
        address newTreasuryWallet
    ) external onlyOwner {
        if (newTreasuryWallet == address(0)) revert InvalidTreasuryWallet();

        // [I-04] Unrolled sum — no loop counter, clearer intent for reviewers.
        uint256 sum = uint256(newBracketPercents[0]) + newBracketPercents[1]
                    + newBracketPercents[2] + newBracketPercents[3]
                    + newBracketPercents[4] + newBracketPercents[5]
                    + newTreasuryPercent;
        if (sum != 10_000) revert PercentSumNot100(sum);

        // [I-05] Capture old wallet for the event before overwriting storage.
        address oldWallet = treasuryWallet;

        bracketPercents = newBracketPercents;
        treasuryPercent = newTreasuryPercent;
        treasuryWallet  = newTreasuryWallet;

        emit RewardDistributionUpdated(newBracketPercents, newTreasuryPercent, oldWallet, newTreasuryWallet);
    }

    /**
     * @notice Escape hatch for a round stuck in DRAWING because VRF never
     *         fulfilled (wrong key hash, dead subscription, dropped request).
     *         Resets the round back to OPEN and pushes endTime forward by
     *         `roundDuration` so buyers don't lose their tickets — they can
     *         keep buying or anyone can call drawNumber again after the new
     *         endTime + drawDelay.
     *
     *         Only callable after STUCK_DRAW_TIMEOUT has elapsed since the
     *         original endTime + drawDelay window opened, to prevent abuse.
     */
    function adminResetStuckDraw(uint256 roundId) external onlyOwner {
        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.DRAWING) revert WrongRoundStatus();

        uint256 readyAt = uint256(r.endTime) + drawDelay + STUCK_DRAW_TIMEOUT;
        if (block.timestamp < readyAt) revert StuckDrawTimeoutNotElapsed(readyAt);

        // [L-04] Cache roundDuration into a local before any state writes so the
        // value used for r.endTime and the emitted event cannot diverge from a
        // concurrent setRoundDuration in a multicall.
        uint256 _dur = roundDuration;
        // [M-02] Guard the uint64 cast same as openRound.
        uint256 endTs = block.timestamp + _dur;
        if (endTs > type(uint64).max) revert EndTimeOverflow();

        uint256 abandonedReq = r.vrfRequestId;
        r.vrfRequestId = 0;
        r.endTime      = uint64(endTs);
        r.status       = RoundStatus.OPEN;

        // [L-03] Free the stale mapping entry from the abandoned request.
        delete _vrfRequestToRound[abandonedReq];

        emit StuckDrawReset(roundId, abandonedReq, r.endTime);
    }

    // ── Admin: orphan recovery ─────────────────────────────────────────────────

    /**
     * @notice Credit USDT sitting on the contract balance into the current OPEN
     *         round's prizePool. Use this to recover funds orphaned by edge
     *         cases — e.g. a zero-buyer round in a pre-fix contract version,
     *         or a direct USDT transfer to the contract that the protocol
     *         can't otherwise account for.
     *
     *         The admin is responsible for verifying off-chain that `amount`
     *         only covers truly-orphaned funds and not USDT owed to past
     *         claimers (sum of `bracketAmounts[i] - bracketPaid[i]` across all
     *         CLAIMABLE rounds, plus the current round's `prizePool`).
     *
     *         Safety: only callable when the current round is OPEN. Bounded
     *         by the contract's USDT balance so the call cannot inflate
     *         prizePool past what's actually on hand.
     */
    function adminCreditOrphanedFunds(uint256 amount) external onlyOwner {
        if (currentRoundId == 0) revert NoActiveRound();
        Round storage r = rounds[currentRoundId];
        if (r.status != RoundStatus.OPEN) revert WrongRoundStatus();

        uint256 bal = usdt.balanceOf(address(this));
        // [orphan-hardening] The advertised prizePool must never exceed the USDT
        // actually on hand. Bounding `r.prizePool + amount` (not just `amount`)
        // closes a double-credit footgun: crediting the same orphaned funds twice
        // would inflate prizePool past the contract balance, so the tail of claims
        // for that round would revert. This makes the contract self-protecting.
        if (r.prizePool + amount > bal) revert InsufficientContractBalance();

        r.prizePool += amount;
        emit OrphanedFundsCredited(currentRoundId, amount);
    }

    // ── Admin: emergency pause ─────────────────────────────────────────────────

    function pause()   external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function getTicket(uint256 roundId, uint256 ticketIndex) external view returns (Ticket memory) {
        return _tickets[roundId][ticketIndex];
    }

    function getTicketCount(uint256 roundId) external view returns (uint256) {
        return _tickets[roundId].length;
    }

    /**
     * @notice Paginated read of tickets for a round. Returns ticket numbers +
     *         owners. Use for frontend "My Tickets" with client-side filter.
     */
    function getTicketsPage(uint256 roundId, uint256 offset, uint256 limit) external view returns (Ticket[] memory page) {
        Ticket[] storage all = _tickets[roundId];
        uint256 total = all.length;
        if (offset >= total) return new Ticket[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new Ticket[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = all[i];
        }
    }

    /// @notice Returns ticket indices owned by `wallet` in `roundId`. O(N) scan.
    function getTicketIndicesByWallet(uint256 roundId, address wallet) external view returns (uint256[] memory) {
        Ticket[] storage all = _tickets[roundId];
        uint256 total = all.length;
        // first pass: count
        uint256 owned;
        for (uint256 i = 0; i < total; i++) {
            if (all[i].owner == wallet) owned++;
        }
        uint256[] memory out = new uint256[](owned);
        uint256 j;
        for (uint256 i = 0; i < total; i++) {
            if (all[i].owner == wallet) {
                out[j++] = i;
            }
        }
        return out;
    }

    function getBracketPercents() external view returns (uint16[6] memory) {
        return bracketPercents;
    }

    /// @notice True if `drawNumber(roundId)` is callable right now.
    function isReadyForDraw(uint256 roundId) external view returns (bool) {
        Round storage r = rounds[roundId];
        if (r.status != RoundStatus.OPEN) return false;
        return block.timestamp >= uint256(r.endTime) + drawDelay;
    }

    /// @notice Pure helper for frontend ticket-matching preview.
    function computeBracket(uint32 winning, uint32 ticket) external pure returns (uint8 matched, int8 bracket) {
        matched = _matchedDigits(winning, ticket);
        bracket = matched >= 1 ? int8(int256(uint256(matched)) - 1) : int8(-1);
    }
}
