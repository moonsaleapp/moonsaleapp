// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/proxy/Clones.sol";
import "./MoonsalePresale.sol";

/**
 * @title MoonsaleFactory
 * @notice Deploys MoonsalePresale contracts and manages platform config.
 *         One factory per chain. The dexRouter is set per-deployment.
 *         Anyone can call createPresale() — no admin approval needed.
 */
contract MoonsaleFactory is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── Events ─────────────────────────────────────────────────────────────────
    event PresaleCreated(
        address indexed presale,
        address indexed creator,
        address indexed token,
        uint256 startTime,
        uint256 endTime
    );
    event LiquidityLocked(
        address indexed lpToken,
        address indexed locker,
        uint256 amount,
        uint256 unlockTime
    );
    event LiquidityUnlocked(address indexed lpToken, address indexed owner, uint256 amount);
    event PlatformFeeUpdated(uint256 newFeeBps);
    event FeeRecipientUpdated(address newRecipient);
    event DexRouterUpdated(address newRouter);
    event MinLockDaysUpdated(uint256 newDays);
    event ListingFeeUpdated(uint256 newFee);
    event PenaltyPercentUpdated(uint256 newBps);
    event PenaltyReceiverUpdated(address newReceiver);
    event ListingFeesClaimed(address indexed recipient, uint256 amount);
    event CreationPausedUpdated(bool paused);
    event LockExtended(uint256 indexed lockId, uint256 newUnlockTime);

    // ── Platform config ────────────────────────────────────────────────────────
    uint256 public platformFeePercent;   // basis points, default 200 (2%)
    address public platformFeeRecipient;
    address public dexRouter;            // Uniswap V2-compatible router for this chain
    uint256 public minLiquidityLockDays; // minimum lock period enforced at deploy
    uint256 public listingFeeNative;     // flat fee in native coin to create presale (0 = free)

    // Early withdrawal penalty (global, applies to all presales on this factory)
    uint256 public penaltyPercent;       // basis points, e.g. 1000 = 10%
    address public penaltyReceiver;      // wallet that receives penalty cuts

    // M-02: pull-based listing fee accumulator
    uint256 public accumulatedListingFees;

    // L-03: emergency pause for new presale creation
    bool public creationPaused;

    uint256 public constant MAX_FEE     = 1000;  // 10% hard cap on platform fee
    uint256 public constant MAX_PENALTY = 3000;  // 30% hard cap on withdrawal penalty

    // ── Presale implementation (clone target) ──────────────────────────────────
    address public immutable presaleImplementation;

    // ── Registry ───────────────────────────────────────────────────────────────
    address[] private _presales;
    mapping(address => bool)      public isPresale;       // quick lookup
    mapping(address => address[]) public creatorPresales; // creator -> their presales

    // ── Liquidity locker ───────────────────────────────────────────────────────
    struct LockRecord {
        address lpToken;
        uint256 amount;
        uint256 unlockTime;
        address owner;       // creator who owns the lock
        bool    withdrawn;
    }

    LockRecord[] public locks;
    mapping(address => uint256[]) public ownerLockIds; // owner -> lock IDs

    // ── Constructor ────────────────────────────────────────────────────────────
    constructor(
        address _presaleImplementation,
        address _dexRouter,
        address _feeRecipient,
        uint256 _platformFeePercent,
        uint256 _minLiquidityLockDays
    ) Ownable(msg.sender) {
        require(_presaleImplementation != address(0), "impl=0");
        require(_dexRouter      != address(0), "router=0");
        require(_feeRecipient   != address(0), "recipient=0");
        require(_platformFeePercent <= MAX_FEE, "fee>10%");
        require(_minLiquidityLockDays > 0,      "lockDays=0");

        presaleImplementation = _presaleImplementation;
        dexRouter            = _dexRouter;
        platformFeeRecipient = _feeRecipient;
        platformFeePercent   = _platformFeePercent;
        minLiquidityLockDays = _minLiquidityLockDays;
    }

    // ── Create presale ─────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new MoonsalePresale contract.
     *         No admin approval — open launch model.
     *         If listingFeeNative > 0, caller must send that amount.
     *
     * @param p                    Presale parameters (see MoonsalePresale.PresaleParams)
     * @param maxAcceptableFeeBps  M-01: creator's upper bound on platform fee; reverts if exceeded
     * @param expectedDexRouter    M-01: creator's expected DEX router; reverts if changed
     * @return presaleAddr         Address of the newly deployed presale contract
     */
    function createPresale(
        MoonsalePresale.PresaleParams memory p,
        uint256 maxAcceptableFeeBps,
        address expectedDexRouter
    ) external payable nonReentrant returns (address presaleAddr) {
        // L-03: emergency pause
        require(!creationPaused, "creation paused");
        // M-01: slippage guards — revert if admin changed fee or router since creator signed
        require(platformFeePercent <= maxAcceptableFeeBps, "fee changed");
        require(dexRouter == expectedDexRouter, "router changed");

        // Collect listing fee (pull-based, M-02) and refund any excess (H-01)
        require(msg.value >= listingFeeNative, "listing fee not paid");
        if (listingFeeNative > 0) {
            accumulatedListingFees += listingFeeNative;
        }
        uint256 excess = msg.value - listingFeeNative;
        if (excess > 0) {
            (bool r, ) = msg.sender.call{value: excess}("");
            require(r, "excess refund failed");
        }

        // Enforce platform-wide minimums
        require(p.liquidityLockDays >= minLiquidityLockDays, "lock below minimum");

        // Force platform fee config from factory (creator cannot override)
        p.platformFeePercent   = platformFeePercent;
        p.platformFeeRecipient = platformFeeRecipient;
        p.dexRouter            = dexRouter;
        p.creator              = msg.sender;

        // Clone the implementation (EIP-1167 minimal proxy) then initialize
        presaleAddr = Clones.clone(presaleImplementation);
        MoonsalePresale(payable(presaleAddr)).initialize(p);

        _presales.push(presaleAddr);
        isPresale[presaleAddr]    = true;
        creatorPresales[msg.sender].push(presaleAddr);

        emit PresaleCreated(presaleAddr, msg.sender, p.token, p.startTime, p.endTime);
    }

    /**
     * @notice Deploy a presale AND transfer the required tokens to it in one transaction.
     *         Caller must have already called ERC20.approve(factory, depositAmount) beforehand.
     *
     * @param p                    Presale parameters
     * @param depositAmount        Exact token amount to pull from caller into the presale contract
     * @param maxAcceptableFeeBps  M-01: creator's upper bound on platform fee; reverts if exceeded
     * @param expectedDexRouter    M-01: creator's expected DEX router; reverts if changed
     * @return presaleAddr         Address of the newly deployed presale contract
     */
    function createPresaleAndDeposit(
        MoonsalePresale.PresaleParams memory p,
        uint256 depositAmount,
        uint256 maxAcceptableFeeBps,
        address expectedDexRouter
    ) external payable nonReentrant returns (address presaleAddr) {
        require(depositAmount > 0, "depositAmount=0");
        // L-03: emergency pause
        require(!creationPaused, "creation paused");
        // M-01: slippage guards
        require(platformFeePercent <= maxAcceptableFeeBps, "fee changed");
        require(dexRouter == expectedDexRouter, "router changed");

        // Collect listing fee (pull-based, M-02) and refund any excess (H-01)
        require(msg.value >= listingFeeNative, "listing fee not paid");
        if (listingFeeNative > 0) {
            accumulatedListingFees += listingFeeNative;
        }
        uint256 excess = msg.value - listingFeeNative;
        if (excess > 0) {
            (bool r, ) = msg.sender.call{value: excess}("");
            require(r, "excess refund failed");
        }

        // Enforce platform-wide minimums
        require(p.liquidityLockDays >= minLiquidityLockDays, "lock below minimum");

        // Force platform fee config from factory
        p.platformFeePercent   = platformFeePercent;
        p.platformFeeRecipient = platformFeeRecipient;
        p.dexRouter            = dexRouter;
        p.creator              = msg.sender;

        // Clone and initialize
        presaleAddr = Clones.clone(presaleImplementation);
        MoonsalePresale(payable(presaleAddr)).initialize(p);

        _presales.push(presaleAddr);
        isPresale[presaleAddr]        = true;
        creatorPresales[msg.sender].push(presaleAddr);

        // Pull tokens from creator directly into the presale contract
        // L-06: balance snapshot to detect fee-on-transfer tokens — reject if received < deposited
        uint256 balBefore = IERC20(p.token).balanceOf(presaleAddr);
        IERC20(p.token).safeTransferFrom(msg.sender, presaleAddr, depositAmount);
        uint256 received = IERC20(p.token).balanceOf(presaleAddr) - balBefore;
        require(received == depositAmount, "Fee detected: exclude contract from fees first");

        emit PresaleCreated(presaleAddr, msg.sender, p.token, p.startTime, p.endTime);
    }

    // ── Liquidity locker ───────────────────────────────────────────────────────

    /**
     * @notice Called by MoonsalePresale.finalize() to lock LP tokens.
     *         Only deployed presale contracts can call this.
     */
    function lockLiquidity(
        address lpToken,
        uint256 amount,
        uint256 unlockTime,
        address lockOwner
    ) external nonReentrant {
        require(isPresale[msg.sender],  "caller not a presale");
        require(lpToken != address(0),   "lpToken=0");
        require(amount > 0,              "amount=0");
        require(unlockTime > block.timestamp, "unlock in past");
        require(lockOwner != address(0), "owner=0");

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

    // ── Extend lock (L-04) ────────────────────────────────────────────────────

    function extendLock(uint256 lockId, uint256 newUnlockTime) external nonReentrant {
        LockRecord storage lock = locks[lockId];
        require(lock.owner == msg.sender,          "not owner");
        require(!lock.withdrawn,                   "already withdrawn");
        require(newUnlockTime > lock.unlockTime,   "must extend further");
        lock.unlockTime = newUnlockTime;
        emit LockExtended(lockId, newUnlockTime);
    }

    // ── Admin: platform config ─────────────────────────────────────────────────

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

    // ── Emergency pause (L-03) ────────────────────────────────────────────────

    function setCreationPaused(bool paused) external onlyOwner {
        creationPaused = paused;
        emit CreationPausedUpdated(paused);
    }

    // ── Listing fee claim (M-02) ───────────────────────────────────────────────

    function claimListingFees() external nonReentrant {
        require(msg.sender == platformFeeRecipient, "not recipient");
        uint256 amount = accumulatedListingFees;
        require(amount > 0, "nothing to claim");
        accumulatedListingFees = 0;
        (bool ok, ) = platformFeeRecipient.call{value: amount}("");
        require(ok, "claim failed");
        emit ListingFeesClaimed(platformFeeRecipient, amount);
    }

    // ── Emergency recovery ─────────────────────────────────────────────────────

    function sweepStuckETH() external onlyOwner nonReentrant {
        uint256 stuckBal = address(this).balance - accumulatedListingFees;
        require(stuckBal > 0, "nothing to sweep");
        (bool ok, ) = platformFeeRecipient.call{value: stuckBal}("");
        require(ok, "sweep failed");
    }

    // ── Registry reads ─────────────────────────────────────────────────────────

    function getAllPresales() external view returns (address[] memory) {
        return _presales;
    }

    function getPresaleCount() external view returns (uint256) {
        return _presales.length;
    }

    function getPresaleAt(uint256 index) external view returns (address) {
        return _presales[index];
    }

    function getCreatorPresales(address creator) external view returns (address[] memory) {
        return creatorPresales[creator];
    }

    function getLock(uint256 lockId) external view returns (LockRecord memory) {
        return locks[lockId];
    }

    function getOwnerLockIds(address owner) external view returns (uint256[] memory) {
        return ownerLockIds[owner];
    }
}
