// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./interfaces/IMoonsaleFairLaunch.sol";

/**
 * @title MoonsaleFairLaunch
 * @notice Fair launch presale where the token price is determined by total raised.
 *         No hardcap. Price = totalRaised / totalTokenPool.
 *         Liquidity is added at the same fair price, ensuring no listing discount.
 *         Uses EIP-1167 minimal proxy pattern (deployed by MoonsaleFairLaunchFactory).
 */
contract MoonsaleFairLaunch is IMoonsaleFairLaunch, Initializable {
    using SafeERC20 for IERC20;

    uint256 public constant PERCENT_DENOMINATOR   = 10_000;
    uint256 public constant MAX_LIQUIDITY_PERCENT = 9_500;  // 95% hard cap
    uint256 public constant EMERGENCY_REFUND_DELAY = 30 days; // H-01: grace period before anyone can force-cancel

    // -- Config (set at init, immutable after)
    address public factory;
    address public creator;
    IERC20  public token;

    uint256 public totalTokenPool;       // actual tokens received at deposit (fee-on-transfer safe)
    uint256 public softcap;              // minimum raise (wei) required for finalization
    uint256 public minBuy;               // 0 = no minimum per contribution
    uint256 public maxBuy;               // 0 = no maximum per wallet
    uint256 public liquidityPercent;     // basis points
    uint256 public liquidityLockDays;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public platformFeePercent;
    address public platformFeeRecipient;
    address public dexRouter;
    bool    public isWhitelistEnabled;

    // -- Mutable state
    Status  public status;
    uint256 public totalRaised;
    uint256 public participantCount;
    uint256 public investorTokenPool;    // set at finalization: tokens for investors
    uint256 public finalizedAt;

    mapping(address => uint256) public contributions;
    mapping(address => uint256) public tokensClaimed;
    mapping(address => bool)    private _isParticipant;
    mapping(address => bool)    public  whitelist;

    // Manual reentrancy guard (proxy pattern avoids ReentrancyGuard constructor issue)
    bool private _locked;
    modifier nonReentrant() {
        require(!_locked, "reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyCreator() {
        require(msg.sender == creator, "not creator");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() { _disableInitializers(); }

    // ── Params struct ─────────────────────────────────────────────────────────────
    struct FairLaunchParams {
        address token;
        uint256 softcap;
        uint256 minBuy;
        uint256 maxBuy;
        uint256 liquidityPercent;
        uint256 liquidityLockDays;
        uint256 startTime;
        uint256 endTime;
        uint256 platformFeePercent;
        address platformFeeRecipient;
        address dexRouter;
        address creator;
        bool    isWhitelistEnabled;
    }

    // ── Initialize (called by factory after clone and token deposit) ──────────────
    function initialize(FairLaunchParams memory p, uint256 _totalTokenPool) external initializer {
        require(p.token                != address(0),           "token=0");
        require(_totalTokenPool         > 0,                    "tokenPool=0");
        require(p.softcap               > 0,                    "softcap=0");
        require(p.liquidityPercent      >= 5100,                "liquidityPercent<51%");
        require(p.liquidityPercent      <= MAX_LIQUIDITY_PERCENT, "liquidityPercent>95%");
        require(p.liquidityLockDays     > 0,                    "lockDays=0");
        require(p.startTime             > block.timestamp,      "startTime in past");
        require(p.endTime               > p.startTime,          "endTime<=startTime");
        require(p.platformFeePercent    <= 1000,                "fee>10%");
        require(p.platformFeeRecipient  != address(0),          "feeRecipient=0");
        require(p.dexRouter             != address(0),          "router=0");
        require(p.creator               != address(0),          "creator=0");
        if (p.maxBuy > 0) require(p.maxBuy >= p.minBuy,        "maxBuy<minBuy");

        factory              = msg.sender;
        creator              = p.creator;
        token                = IERC20(p.token);
        totalTokenPool       = _totalTokenPool;
        softcap              = p.softcap;
        minBuy               = p.minBuy;
        maxBuy               = p.maxBuy;
        liquidityPercent     = p.liquidityPercent;
        liquidityLockDays    = p.liquidityLockDays;
        startTime            = p.startTime;
        endTime              = p.endTime;
        platformFeePercent   = p.platformFeePercent;
        platformFeeRecipient = p.platformFeeRecipient;
        dexRouter            = p.dexRouter;
        isWhitelistEnabled   = p.isWhitelistEnabled;
        status               = Status.Pending;
    }

    // ── Contribute ────────────────────────────────────────────────────────────────
    function contribute() external payable override nonReentrant {
        require(block.timestamp >= startTime, "not started");
        require(block.timestamp <= endTime,   "sale ended");
        require(status == Status.Pending || status == Status.Active, "not open");
        require(msg.value > 0, "zero contribution");

        if (isWhitelistEnabled) {
            require(whitelist[msg.sender], "not whitelisted");
        }

        uint256 alreadyContributed = contributions[msg.sender];

        // Cap at per-wallet max (fair launches have no hardcap)
        uint256 accepted = msg.value;
        if (maxBuy > 0) {
            require(alreadyContributed < maxBuy, "wallet cap reached");
            uint256 walletRemaining = maxBuy - alreadyContributed;
            if (accepted > walletRemaining) accepted = walletRemaining;
        }

        // Enforce minBuy only when the amount wasn't force-capped by the wallet limit
        if (minBuy > 0) {
            require(accepted >= minBuy || accepted < msg.value, "below minBuy");
        }

        if (status == Status.Pending) {
            status = Status.Active;
        }

        if (!_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = true;
            participantCount++;
        }

        contributions[msg.sender] = alreadyContributed + accepted;
        totalRaised               += accepted;

        emit Contributed(msg.sender, accepted);

        // Refund any excess ETH that couldn't be accepted due to wallet cap
        uint256 excess = msg.value - accepted;
        if (excess > 0) {
            (bool ok, ) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    // ── Finalize ──────────────────────────────────────────────────────────────────
    /**
     * @notice Finalizes the fair launch after end time if softcap is reached.
     *         Price = totalRaised / totalTokenPool (fair price for all).
     *         Liquidity uses the same price, so DEX listing price = fair launch price.
     *
     * Token math:
     *   liqTokens    = liqNative * totalTokenPool / totalRaised
     *   investorPool = totalTokenPool - usedToken  (M-04: leftover tokens from DEX add go to investors)
     *   creator gets = netRaised - usedETH          (M-04: leftover ETH from DEX add goes to creator)
     */
    function finalize() external override onlyCreator nonReentrant {
        require(
            status == Status.Active || status == Status.Pending,
            "cannot finalize"
        );
        require(block.timestamp > endTime, "sale still running");
        require(totalRaised >= softcap,    "softcap not reached");

        uint256 contractTokenBal = token.balanceOf(address(this));
        require(contractTokenBal >= totalTokenPool, "insufficient token deposit");

        // H-02: abort early if the DEX pair has already been seeded with reserves.
        //       An attacker can grief finalization by pre-seeding the pair at a skewed
        //       price so the router's slippage check always fails. If this happens the
        //       creator should cancel via cancelFairLaunch(), allowing investors to refund.
        IUniswapV2Router02 router = IUniswapV2Router02(dexRouter);
        address pairAddr = IUniswapV2Factory(router.factory()).getPair(address(token), router.WETH());
        if (pairAddr != address(0)) {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pairAddr).getReserves();
            require(r0 == 0 && r1 == 0, "Pair pre-seeded; cancel to refund investors");
        }

        status      = Status.Finalized;
        finalizedAt = block.timestamp;

        // 1. Platform fee (taken from totalRaised)
        uint256 fee       = (totalRaised * platformFeePercent) / PERCENT_DENOMINATOR;
        uint256 netRaised = totalRaised - fee;

        if (fee > 0) {
            (bool feeOk, ) = platformFeeRecipient.call{value: fee}("");
            require(feeOk, "fee transfer failed");
        }

        // 2. Calculate liquidity split at the fair price
        //    liqNative = netRaised * liqPercent
        //    liqTokens = liqNative * totalTokenPool / totalRaised  (same price ratio)
        uint256 liqNative = (netRaised * liquidityPercent) / PERCENT_DENOMINATOR;
        uint256 liqTokens = (liqNative * totalTokenPool) / totalRaised;

        // 3. Add liquidity to DEX
        token.forceApprove(dexRouter, liqTokens);
        uint256 amountTokenMin = liqTokens * 9_800 / 10_000;
        uint256 amountETHMin   = liqNative * 9_800 / 10_000;
        (uint256 usedToken, uint256 usedETH, uint256 liquidity) = router.addLiquidityETH{value: liqNative}(
            address(token),
            liqTokens,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp + 600
        );

        // M-04: fold leftover tokens into investor pool; leftover ETH into creator proceeds.
        //       The router may not use all of liqTokens/liqNative if the existing pair price
        //       differs slightly, leaving small amounts unspent in this contract.
        investorTokenPool = totalTokenPool - usedToken;
        require(investorTokenPool > 0, "investorPool=0");

        // 4. Lock LP tokens via factory
        // If the pair was new (pairAddr == 0 before addLiquidityETH), fetch the address now
        if (pairAddr == address(0)) {
            pairAddr = IUniswapV2Factory(router.factory()).getPair(address(token), router.WETH());
        }
        uint256 lockUntil = block.timestamp + (liquidityLockDays * 1 days);
        IERC20(pairAddr).forceApprove(factory, liquidity);
        IMoonsaleFairLaunchFactory(factory).lockLiquidity(pairAddr, liquidity, lockUntil, creator);

        // 5. Creator proceeds (M-04: actual ETH not used for liquidity is returned to creator)
        uint256 creatorProceeds = netRaised - usedETH;
        if (creatorProceeds > 0) {
            (bool ok, ) = creator.call{value: creatorProceeds}("");
            require(ok, "creator transfer failed");
        }

        emit Finalized(totalRaised, usedETH, fee, investorTokenPool);
    }

    // ── Claim (instant, no vesting) ───────────────────────────────────────────────
    function claim() external override nonReentrant {
        require(status == Status.Finalized, "not finalized");
        uint256 claimable = getClaimableTokens(msg.sender);
        require(claimable > 0, "nothing to claim");

        tokensClaimed[msg.sender] += claimable;
        token.safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    // ── Early withdrawal (with penalty) ───────────────────────────────────────────
    function withdrawContribution() external override nonReentrant {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "not active");
        require(status == Status.Pending || status == Status.Active, "not open");
        require(finalizedAt == 0, "already finalized");

        uint256 amount = contributions[msg.sender];
        require(amount > 0, "no contribution");

        uint256 penaltyBps  = IMoonsaleFairLaunchFactory(factory).penaltyPercent();
        address penaltyAddr = IMoonsaleFairLaunchFactory(factory).penaltyReceiver();

        uint256 penalty      = (penaltyAddr != address(0)) ? (amount * penaltyBps) / PERCENT_DENOMINATOR : 0;
        uint256 refundAmount = amount - penalty;

        contributions[msg.sender] = 0;
        totalRaised               -= amount;

        // Decrement participant count — this contributor is fully exiting
        if (_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = false;
            if (participantCount > 0) participantCount--;
        }

        if (penalty > 0) {
            (bool ok1, ) = penaltyAddr.call{value: penalty}("");
            require(ok1, "penalty transfer failed");
        }
        (bool ok2, ) = msg.sender.call{value: refundAmount}("");
        require(ok2, "refund failed");

        emit ContributionWithdrawn(msg.sender, amount, penalty);
    }

    // ── Refund (after failure or cancellation) ───────────────────────────────────
    function refund() external override nonReentrant {
        require(
            status == Status.Failed ||
            status == Status.Cancelled ||
            _isRefundable(),
            "refunds not open"
        );
        // Transition to Failed only for the auto-fail path (not for explicit cancel)
        if (status != Status.Failed && status != Status.Cancelled) {
            status = Status.Failed;
        }

        uint256 amount = contributions[msg.sender];
        require(amount > 0, "no contribution");

        contributions[msg.sender] = 0;
        totalRaised               -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");

        emit Refunded(msg.sender, amount);
    }

    // ── Emergency refund (H-01: creator ghosting after 30-day grace period) ───────
    /**
     * @notice Anyone can call this after EMERGENCY_REFUND_DELAY past endTime if the
     *         sale was never finalized or cancelled. Permanently cancels the launch
     *         (so all other contributors can use refund()), and immediately refunds
     *         the caller if they contributed.
     */
    function emergencyRefund() external override nonReentrant {
        require(block.timestamp > endTime + EMERGENCY_REFUND_DELAY, "grace period not over");
        require(
            status == Status.Active || status == Status.Pending,
            "sale already resolved"
        );

        // Permanently cancel: unblocks creator token withdrawal and allows all investors to refund()
        status = Status.Cancelled;
        emit EmergencyCancelled(msg.sender);

        // Immediately refund the caller if they have a contribution
        uint256 amount = contributions[msg.sender];
        if (amount > 0) {
            contributions[msg.sender] = 0;
            totalRaised -= amount;
            (bool ok, ) = msg.sender.call{value: amount}("");
            require(ok, "refund failed");
            emit Refunded(msg.sender, amount);
        }
    }

    function _isRefundable() internal view returns (bool) {
        return block.timestamp > endTime && totalRaised < softcap;
    }

    // ── Cancel ────────────────────────────────────────────────────────────────────
    function cancelFairLaunch() external override onlyCreator {
        require(
            status == Status.Pending || status == Status.Active,
            "cannot cancel"
        );
        status = Status.Cancelled;
        emit Cancelled();
    }

    // ── Creator token withdrawal (failed, cancelled, or expired without softcap) ──
    function withdrawCreatorTokens() external override onlyCreator nonReentrant {
        require(
            status == Status.Failed ||
            status == Status.Cancelled ||
            _isRefundable(),
            "not failed/cancelled"
        );
        if (status != Status.Failed && status != Status.Cancelled) {
            status = Status.Failed;
        }
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "no tokens to withdraw");
        token.safeTransfer(creator, bal);
        emit CreatorTokensWithdrawn(creator, bal);
    }

    // ── Whitelist management (creator only) ───────────────────────────────────────
    function setWhitelistEnabled(bool enabled) external onlyCreator {
        isWhitelistEnabled = enabled;
        emit WhitelistToggled(enabled);
    }

    // L-03: cap per-call batch at 200 to avoid gas-limit DoS
    // L-04: emit events so indexers can track whitelist state
    function addToWhitelist(address[] calldata addresses) external onlyCreator {
        require(addresses.length <= 200, "max 200 per call");
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelist[addresses[i]] = true;
            emit WhitelistChanged(addresses[i], true);
        }
    }

    function removeFromWhitelist(address[] calldata addresses) external onlyCreator {
        require(addresses.length <= 200, "max 200 per call");
        for (uint256 i = 0; i < addresses.length; i++) {
            whitelist[addresses[i]] = false;
            emit WhitelistChanged(addresses[i], false);
        }
    }

    // ── View functions ────────────────────────────────────────────────────────────

    /**
     * @notice Returns claimable tokens for an investor after finalization.
     *         Formula: contributions[investor] * investorTokenPool / totalRaised
     */
    function getClaimableTokens(address investor) public view override returns (uint256) {
        if (status != Status.Finalized || investorTokenPool == 0 || totalRaised == 0) return 0;
        uint256 entitled = (contributions[investor] * investorTokenPool) / totalRaised;
        uint256 claimed  = tokensClaimed[investor];
        return entitled > claimed ? entitled - claimed : 0;
    }

    /**
     * @notice Returns the current estimated token price in native currency (wei per token, scaled 1e18).
     *         Updates in real-time as contributions come in.
     */
    function getEstimatedTokenPrice() external view override returns (uint256) {
        if (totalTokenPool == 0 || totalRaised == 0) return 0;
        return (totalRaised * 1e18) / totalTokenPool;
    }

    function getContribution(address investor) external view override returns (uint256) {
        return contributions[investor];
    }

    function getTotalRaised()      external view override returns (uint256) { return totalRaised; }
    function getParticipantCount() external view override returns (uint256) { return participantCount; }
    function getStatus()           external view override returns (Status)  { return status; }

    function isFairLaunchActive() external view override returns (bool) {
        return (status == Status.Pending || status == Status.Active) &&
               block.timestamp >= startTime &&
               block.timestamp <= endTime;
    }

    receive() external payable {}
}

// ── DEX interfaces ────────────────────────────────────────────────────────────────
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH()    external pure returns (address);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface IMoonsaleFairLaunchFactory {
    function lockLiquidity(address lpToken, uint256 amount, uint256 unlockTime, address owner) external;
    function penaltyPercent() external view returns (uint256);
    function penaltyReceiver() external view returns (address);
}
