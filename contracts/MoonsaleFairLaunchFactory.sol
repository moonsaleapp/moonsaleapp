// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./MoonsaleFairLaunch.sol";

/**
 * @title MoonsaleFairLaunchFactory
 * @notice Deploys MoonsaleFairLaunch contracts and manages platform config.
 *         Separate from MoonsaleFactory so fair launch settings are independent.
 *         Includes its own liquidity locker for LP tokens.
 */
contract MoonsaleFairLaunchFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Events ─────────────────────────────────────────────────────────────────
    event FairLaunchCreated(
        address indexed fairLaunch,
        address indexed creator,
        address indexed token,
        uint256 startTime,
        uint256 endTime
    );
    event LiquidityLocked(address indexed lpToken, address indexed locker, uint256 amount, uint256 unlockTime);
    event LiquidityUnlocked(address indexed lpToken, address indexed owner, uint256 amount);
    event LockExtended(uint256 indexed lockId, uint256 newUnlockTime);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);
    event DexRouterUpdated(address newRouter);
    event MinLockDaysUpdated(uint256 newDays);
    event ListingFeeUpdated(uint256 newFee);
    event ListingFeesClaimed(address indexed recipient, uint256 amount);
    event PenaltyPercentUpdated(uint256 newBps);
    event PenaltyReceiverUpdated(address newReceiver);
    event CreationPaused(bool paused);

    // ── Platform config (independent from presale factory) ────────────────────
    uint256 public platformFeePercent;
    address public platformFeeRecipient;
    address public dexRouter;
    uint256 public minLiquidityLockDays;
    uint256 public listingFeeNative;

    uint256 public penaltyPercent;
    address public penaltyReceiver;

    // Pull-based listing fee accumulator (M-02: avoids push-to-recipient DoS)
    uint256 public accumulatedListingFees;

    bool public creationPaused;

    uint256 public constant MAX_FEE     = 1000;   // 10%
    uint256 public constant MAX_PENALTY = 3000;   // 30%

    // ── Fair launch implementation (clone target) ─────────────────────────────
    address public immutable fairLaunchImplementation;

    // ── Registry ──────────────────────────────────────────────────────────────
    address[] private _fairLaunches;
    mapping(address => bool)      public isFairLaunch;
    mapping(address => address[]) public creatorFairLaunches;

    // ── Liquidity locker ──────────────────────────────────────────────────────
    struct LockRecord {
        address lpToken;
        uint256 amount;
        uint256 unlockTime;
        address owner;
        bool    withdrawn;
    }

    LockRecord[] public locks;
    mapping(address => uint256[]) public ownerLockIds;

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address _impl,
        address _dexRouter,
        address _feeRecipient,
        uint256 _platformFeePercent,
        uint256 _minLiquidityLockDays
    ) Ownable(msg.sender) {
        require(_impl           != address(0), "impl=0");
        require(_dexRouter      != address(0), "router=0");
        require(_feeRecipient   != address(0), "recipient=0");
        require(_platformFeePercent  <= MAX_FEE, "fee>10%");
        require(_minLiquidityLockDays > 0,       "lockDays=0");

        fairLaunchImplementation = _impl;
        dexRouter                = _dexRouter;
        platformFeeRecipient     = _feeRecipient;
        platformFeePercent       = _platformFeePercent;
        minLiquidityLockDays     = _minLiquidityLockDays;
    }

    // ── Create fair launch ────────────────────────────────────────────────────

    /**
     * @notice Deploy a new MoonsaleFairLaunch and deposit creator tokens in one tx.
     *         Caller must have already approved this factory to spend depositAmount tokens.
     *         If listingFeeNative > 0, caller must send at least that amount as msg.value.
     *         Any msg.value in excess of listingFeeNative is refunded to the caller.
     *
     * @param p              Fair launch parameters
     * @param depositAmount  Exact token amount to pull from creator into the fair launch
     */
    function createFairLaunchAndDeposit(
        MoonsaleFairLaunch.FairLaunchParams memory p,
        uint256 depositAmount
    ) external payable nonReentrant returns (address flAddr) {
        require(!creationPaused, "creation paused");
        require(depositAmount > 0, "depositAmount=0");
        require(msg.value >= listingFeeNative, "listing fee not paid");

        // M-02: accumulate listing fee instead of push-to-recipient.
        // Prevents a broken/malicious recipient from bricking fair launch creation.
        accumulatedListingFees += listingFeeNative;

        // Enforce minimum lock days
        require(p.liquidityLockDays >= minLiquidityLockDays, "lock below minimum");

        // Force platform config from factory
        p.platformFeePercent   = platformFeePercent;
        p.platformFeeRecipient = platformFeeRecipient;
        p.dexRouter            = dexRouter;
        p.creator              = msg.sender;

        // Clone first, then transfer tokens so we can snapshot the actual received amount
        flAddr = Clones.clone(fairLaunchImplementation);

        uint256 balBefore = IERC20(p.token).balanceOf(flAddr);
        IERC20(p.token).safeTransferFrom(msg.sender, flAddr, depositAmount);
        uint256 received = IERC20(p.token).balanceOf(flAddr) - balBefore;
        require(received > 0, "no tokens received");
        // L-06: reject fee-on-transfer tokens — creator must exclude this contract from fees first
        require(received == depositAmount, "Fee detected: exclude contract from fees first");

        MoonsaleFairLaunch(payable(flAddr)).initialize(p, received);

        _fairLaunches.push(flAddr);
        isFairLaunch[flAddr]                   = true;
        creatorFairLaunches[msg.sender].push(flAddr);

        emit FairLaunchCreated(flAddr, msg.sender, p.token, p.startTime, p.endTime);

        // Refund any ETH sent above the listing fee
        uint256 excess = msg.value - listingFeeNative;
        if (excess > 0) {
            (bool refundOk, ) = msg.sender.call{value: excess}("");
            require(refundOk, "excess refund failed");
        }
    }

    // ── Liquidity locker (called by MoonsaleFairLaunch.finalize) ─────────────
    function lockLiquidity(
        address lpToken,
        uint256 amount,
        uint256 unlockTime,
        address lockOwner
    ) external nonReentrant {
        require(isFairLaunch[msg.sender], "caller not a fair launch");
        require(lpToken    != address(0), "lpToken=0");
        require(amount      > 0,          "amount=0");
        require(unlockTime  > block.timestamp, "unlock in past");
        require(lockOwner  != address(0), "owner=0");

        IERC20(lpToken).safeTransferFrom(msg.sender, address(this), amount);

        uint256 lockId = locks.length;
        locks.push(LockRecord({
            lpToken:    lpToken,
            amount:     amount,
            unlockTime: unlockTime,
            owner:      lockOwner,
            withdrawn:  false
        }));
        ownerLockIds[lockOwner].push(lockId);

        emit LiquidityLocked(lpToken, lockOwner, amount, unlockTime);
    }

    /**
     * @notice LP token owner withdraws after lock expires.
     */
    function unlockLiquidity(uint256 lockId) external nonReentrant {
        LockRecord storage lock = locks[lockId];
        require(lock.owner == msg.sender,           "not owner");
        require(!lock.withdrawn,                    "already withdrawn");
        require(block.timestamp >= lock.unlockTime, "still locked");

        lock.withdrawn = true;
        IERC20(lock.lpToken).safeTransfer(msg.sender, lock.amount);

        emit LiquidityUnlocked(lock.lpToken, msg.sender, lock.amount);
    }

    /**
     * @notice Lock owner can extend (never shorten) the unlock time.
     */
    function extendLock(uint256 lockId, uint256 newUnlockTime) external {
        LockRecord storage lock = locks[lockId];
        require(lock.owner == msg.sender,      "not owner");
        require(!lock.withdrawn,               "already withdrawn");
        require(newUnlockTime > lock.unlockTime, "new time not later");
        lock.unlockTime = newUnlockTime;
        emit LockExtended(lockId, newUnlockTime);
    }

    // ── Admin: platform config ────────────────────────────────────────────────
    function setPlatformFee(uint256 feeBps) external onlyOwner {
        require(feeBps <= MAX_FEE, "fee>10%");
        platformFeePercent = feeBps;
        emit PlatformFeeUpdated(feeBps);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "recipient=0");
        platformFeeRecipient = recipient;
        emit FeeRecipientUpdated(recipient);
    }

    function setDexRouter(address router) external onlyOwner {
        require(router != address(0), "router=0");
        dexRouter = router;
        emit DexRouterUpdated(router);
    }

    function setMinLiquidityLockDays(uint256 days_) external onlyOwner {
        require(days_ > 0, "days=0");
        minLiquidityLockDays = days_;
        emit MinLockDaysUpdated(days_);
    }

    function setListingFee(uint256 feeNative) external onlyOwner {
        listingFeeNative = feeNative;
        emit ListingFeeUpdated(feeNative);
    }

    function setPenaltyPercent(uint256 bps) external onlyOwner {
        require(bps <= MAX_PENALTY, "penalty>30%");
        penaltyPercent = bps;
        emit PenaltyPercentUpdated(bps);
    }

    function setPenaltyReceiver(address receiver) external onlyOwner {
        penaltyReceiver = receiver;
        emit PenaltyReceiverUpdated(receiver);
    }

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPaused(paused);
    }

    /**
     * @notice Claim all accumulated listing fees. Uses pull pattern to avoid
     *         sending ETH inline during fair launch creation (M-02).
     */
    function claimListingFees() external onlyOwner nonReentrant {
        uint256 amount = accumulatedListingFees;
        require(amount > 0, "nothing to claim");
        accumulatedListingFees = 0;
        (bool ok, ) = platformFeeRecipient.call{value: amount}("");
        require(ok, "claim failed");
        emit ListingFeesClaimed(platformFeeRecipient, amount);
    }

    /**
     * @notice Recover ETH accidentally force-sent to this contract (e.g. via selfdestruct).
     *         Does not touch accumulated listing fees.
     */
    function sweepStuckETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > accumulatedListingFees, "nothing to sweep");
        uint256 sweepAmount = balance - accumulatedListingFees;
        (bool ok, ) = platformFeeRecipient.call{value: sweepAmount}("");
        require(ok, "sweep failed");
    }

    // ── Registry reads ────────────────────────────────────────────────────────
    function getAllFairLaunches() external view returns (address[] memory) {
        return _fairLaunches;
    }

    function getFairLaunchCount() external view returns (uint256) {
        return _fairLaunches.length;
    }

    function getFairLaunchAt(uint256 index) external view returns (address) {
        return _fairLaunches[index];
    }

    function getCreatorFairLaunches(address creator) external view returns (address[] memory) {
        return creatorFairLaunches[creator];
    }

    function getLock(uint256 lockId) external view returns (LockRecord memory) {
        return locks[lockId];
    }

    function getOwnerLockIds(address owner) external view returns (uint256[] memory) {
        return ownerLockIds[owner];
    }

    receive() external payable {}
}
