// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import "./interfaces/IMoonsalePresale.sol";

/**
 * @title MoonsalePresale
 * @notice One clone per presale. Uses EIP-1167 minimal proxy pattern so that
 *         createPresale() costs ~400k gas instead of ~34M (deploying a full copy).
 *
 *         MoonsaleFactory deploys a single implementation of this contract and
 *         calls Clones.clone() + initialize() for each new presale.
 */
contract MoonsalePresale is IMoonsalePresale, Initializable {
    using SafeERC20 for IERC20;

    // ── Constants ──────────────────────────────────────────────────────────────
    uint256 public constant PERCENT_DENOMINATOR    = 10_000; // basis points (100 = 1%)
    uint256 public constant FINALIZE_GRACE_PERIOD  = 30 days;

    // ── Storage (was immutable — proxy pattern requires regular storage) ────────
    address public factory;
    address public creator;
    IERC20  public token;

    uint256 public presaleRate;
    uint256 public listingRate;
    uint256 public softcap;
    uint256 public hardcap;
    uint256 public minBuy;
    uint256 public maxBuy;
    uint256 public liquidityPercent;
    uint256 public liquidityLockDays;
    uint256 public startTime;
    uint256 public endTime;
    uint256 public vestingPercentTGE;
    uint256 public vestingDurationDays;
    uint256 public platformFeePercent;
    address public platformFeeRecipient;
    address public dexRouter;

    // ── Reentrancy guard (manual — avoids ReentrancyGuard constructor issue) ───
    bool private _locked;

    modifier nonReentrant() {
        require(!_locked, "reentrant call");
        _locked = true;
        _;
        _locked = false;
    }

    // ── Mutable state ──────────────────────────────────────────────────────────
    Status  public status;
    uint256 public totalRaised;
    uint256 public participantCount;
    uint256 public finalizedAt;

    mapping(address => uint256) public contributions;
    mapping(address => uint256) public tokensClaimed;
    mapping(address => bool)    private _isParticipant;

    // ── Disable direct initialization of implementation ─────────────────────────
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer (called by factory after clone) ────────────────────────────

    struct PresaleParams {
        address token;
        uint256 presaleRate;
        uint256 listingRate;
        uint256 softcap;
        uint256 hardcap;
        uint256 minBuy;
        uint256 maxBuy;
        uint256 liquidityPercent;
        uint256 liquidityLockDays;
        uint256 startTime;
        uint256 endTime;
        uint256 vestingPercentTGE;
        uint256 vestingDurationDays;
        uint256 platformFeePercent;
        address platformFeeRecipient;
        address dexRouter;
        address creator;
    }

    function initialize(PresaleParams memory p) external initializer {
        require(p.token               != address(0), "token=0");
        require(p.presaleRate          > 0,          "presaleRate=0");
        require(p.listingRate          > 0,          "listingRate=0");
        require(p.listingRate          < p.presaleRate, "listingRate>=presaleRate");
        require(p.softcap              > 0,          "softcap=0");
        require(p.hardcap             >= p.softcap,  "hardcap<softcap");
        require(p.minBuy               > 0,          "minBuy=0");
        require(p.maxBuy              >= p.minBuy,   "maxBuy<minBuy");
        require(p.liquidityPercent    >= 5100,        "liquidityPercent<51%");
        require(p.liquidityPercent    <= 10_000,      "liquidityPercent>100%");
        require(p.liquidityLockDays    > 0,          "lockDays=0");
        require(p.startTime           > block.timestamp, "startTime in past");
        require(p.endTime             > p.startTime, "endTime<=startTime");
        require(p.vestingPercentTGE   <= 10_000,     "vestingTGE>100%");
        require(p.platformFeePercent  <= 1000,       "fee>10%");
        require(p.platformFeeRecipient != address(0),"feeRecipient=0");
        require(p.dexRouter           != address(0), "router=0");
        require(p.creator             != address(0), "creator=0");

        factory              = msg.sender;
        creator              = p.creator;
        token                = IERC20(p.token);
        presaleRate          = p.presaleRate;
        listingRate          = p.listingRate;
        softcap              = p.softcap;
        hardcap              = p.hardcap;
        minBuy               = p.minBuy;
        maxBuy               = p.maxBuy;
        liquidityPercent     = p.liquidityPercent;
        liquidityLockDays    = p.liquidityLockDays;
        startTime            = p.startTime;
        endTime              = p.endTime;
        vestingPercentTGE    = p.vestingPercentTGE;
        vestingDurationDays  = p.vestingDurationDays;
        platformFeePercent   = p.platformFeePercent;
        platformFeeRecipient = p.platformFeeRecipient;
        dexRouter            = p.dexRouter;
        status               = Status.Pending;
    }

    // ── Modifiers ──────────────────────────────────────────────────────────────
    modifier onlyCreator() {
        require(msg.sender == creator, "not creator");
        _;
    }

    modifier whenActive() {
        _checkActive();
        _;
    }

    function _checkActive() internal view {
        require(
            block.timestamp >= startTime &&
            block.timestamp <= endTime   &&
            (status == Status.Active || status == Status.Pending),
            "presale not active"
        );
    }

    // ── Core: contribute ───────────────────────────────────────────────────────
    function contribute() external payable override nonReentrant {
        require(block.timestamp >= startTime, "not started");
        require(block.timestamp <= endTime,   "presale ended");
        require(status == Status.Pending || status == Status.Active, "not open");

        uint256 remaining = hardcap - totalRaised;
        require(remaining > 0, "hardcap filled");

        uint256 alreadyContributed = contributions[msg.sender];
        require(alreadyContributed < maxBuy, "wallet cap reached");

        // Accept up to what fits: hardcap space and per-wallet cap
        uint256 walletRemaining = maxBuy - alreadyContributed;
        uint256 accepted = msg.value;
        if (accepted > remaining)       accepted = remaining;
        if (accepted > walletRemaining) accepted = walletRemaining;

        // Enforce minBuy only when the amount wasn't forced smaller by a cap
        require(accepted >= minBuy || accepted < msg.value, "below minBuy");

        if (status == Status.Pending) status = Status.Active;

        if (!_isParticipant[msg.sender]) {
            _isParticipant[msg.sender] = true;
            participantCount++;
        }

        contributions[msg.sender] = alreadyContributed + accepted;
        totalRaised += accepted;

        uint256 tokenAmount = (accepted * presaleRate) / 1e18;
        emit TokensPurchased(msg.sender, accepted, tokenAmount);

        if (totalRaised == hardcap) status = Status.Filled;

        // Refund any excess ETH that couldn't be accepted
        uint256 excess = msg.value - accepted;
        if (excess > 0) {
            (bool ok, ) = msg.sender.call{value: excess}("");
            require(ok, "refund failed");
        }
    }

    // ── Core: finalize ─────────────────────────────────────────────────────────
    function finalize() external override onlyCreator nonReentrant {
        require(
            status == Status.Active ||
            status == Status.Filled ||
            status == Status.Pending,
            "cannot finalize"
        );
        require(
            block.timestamp > endTime || status == Status.Filled,
            "presale still running"
        );
        require(totalRaised >= softcap, "softcap not reached");

        status      = Status.Finalized;
        finalizedAt = block.timestamp;

        // 1. Platform fee
        uint256 fee = (totalRaised * platformFeePercent) / PERCENT_DENOMINATOR;
        if (fee > 0) {
            (bool feeOk, ) = platformFeeRecipient.call{value: fee}("");
            require(feeOk, "fee transfer failed");
        }

        // 2. Liquidity
        uint256 afterFee           = totalRaised - fee;
        uint256 nativeForLiquidity    = (afterFee * liquidityPercent) / PERCENT_DENOMINATOR;
        uint256 tokensForLiquidity    = (nativeForLiquidity * listingRate) / 1e18;
        uint256 tokensForDistribution = (totalRaised * presaleRate) / 1e18;
        require(
            token.balanceOf(address(this)) >= tokensForLiquidity + tokensForDistribution,
            "insufficient tokens deposited"
        );

        IUniswapV2Router02 router = IUniswapV2Router02(dexRouter);

        // L-07 / H-02: abort if the DEX pair already has reserves — a pre-seeded pair prevents
        // finalization via addLiquidityETH slippage checks.
        address pairAddr = IUniswapV2Factory(router.factory()).getPair(address(token), router.WETH());
        if (pairAddr != address(0)) {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pairAddr).getReserves();
            require(r0 == 0 && r1 == 0, "Pair pre-seeded; cancel to refund investors");
        }

        token.forceApprove(dexRouter, tokensForLiquidity);
        // 2% slippage tolerance — reverts if a sandwich bot has skewed the pool price
        uint256 amountTokenMin = tokensForLiquidity * 9_800 / 10_000;
        uint256 amountETHMin   = nativeForLiquidity * 9_800 / 10_000;
        // M-04: capture actual amounts used — router may return unused tokens/ETH
        (uint256 usedToken, uint256 usedETH, uint256 liquidity) = router.addLiquidityETH{value: nativeForLiquidity}(
            address(token),
            tokensForLiquidity,
            amountTokenMin,
            amountETHMin,
            address(this),
            block.timestamp + 600
        );

        // 3. Lock LP tokens via factory
        if (pairAddr == address(0)) {
            pairAddr = IUniswapV2Factory(router.factory()).getPair(address(token), router.WETH());
        }
        uint256 lockUntil = block.timestamp + (liquidityLockDays * 1 days);
        IERC20(pairAddr).forceApprove(factory, liquidity);
        IMoonsaleFactory(factory).lockLiquidity(pairAddr, liquidity, lockUntil, creator);

        // 4. Creator proceeds (M-04: leftover ETH and tokens from DEX add go to creator)
        uint256 creatorProceeds = afterFee - usedETH;
        if (creatorProceeds > 0) {
            (bool ok, ) = creator.call{value: creatorProceeds}("");
            require(ok, "creator transfer failed");
        }
        uint256 leftoverTokens = tokensForLiquidity - usedToken;
        if (leftoverTokens > 0) {
            token.safeTransfer(creator, leftoverTokens);
        }

        emit Finalized(totalRaised, nativeForLiquidity, fee);
    }

    // ── Core: claim ────────────────────────────────────────────────────────────
    function claim() external override nonReentrant {
        require(status == Status.Finalized, "not finalized");
        uint256 claimable = getClaimableTokens(msg.sender);
        require(claimable > 0, "nothing to claim");

        tokensClaimed[msg.sender] += claimable;
        token.safeTransfer(msg.sender, claimable);

        emit TokensClaimed(msg.sender, claimable);
    }

    // ── Core: early withdraw with penalty ─────────────────────────────────────
    /**
     * @notice Contributor withdraws during an active presale, incurring a penalty.
     *         Penalty % and receiver are read from the factory (global admin setting).
     *         Not allowed once hardcap is filled or presale is finalized.
     */
    function withdrawContribution() external override nonReentrant {
        require(block.timestamp >= startTime && block.timestamp <= endTime, "presale not active");
        require(status == Status.Pending || status == Status.Active, "not open");
        require(finalizedAt == 0, "already finalized");
        require(totalRaised < hardcap, "hardcap filled");

        uint256 amount = contributions[msg.sender];
        require(amount > 0, "no contribution");

        // Read global penalty settings from factory (capped at 25% regardless of factory value)
        uint256 penaltyBps  = IMoonsaleFactory(factory).penaltyPercent();
        if (penaltyBps > 2500) penaltyBps = 2500;
        address penaltyAddr = IMoonsaleFactory(factory).penaltyReceiver();

        // Penalty only applies when a receiver is configured
        uint256 penalty      = (penaltyAddr != address(0)) ? (amount * penaltyBps) / PERCENT_DENOMINATOR : 0;
        uint256 refundAmount = amount - penalty;

        // Update state before transfers
        contributions[msg.sender] = 0;
        totalRaised -= amount;

        // Send penalty to receiver
        if (penalty > 0) {
            (bool ok1, ) = penaltyAddr.call{value: penalty}("");
            require(ok1, "penalty transfer failed");
        }

        // Refund remainder to contributor
        (bool ok2, ) = msg.sender.call{value: refundAmount}("");
        require(ok2, "refund failed");

        emit ContributionWithdrawn(msg.sender, amount, penalty);
    }

    // ── Core: refund ───────────────────────────────────────────────────────────
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
        totalRaised -= amount;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "refund failed");

        emit Refunded(msg.sender, amount);
    }

    // ── Core: creator token recovery (failed, cancelled, or expired without softcap) ────
    function withdrawCreatorTokens() external override onlyCreator nonReentrant {
        require(
            status == Status.Failed ||
            status == Status.Cancelled ||
            _isRefundable(),
            "not failed/cancelled"
        );
        // Auto-transition to Failed when presale expired without reaching softcap
        if (status != Status.Failed && status != Status.Cancelled) {
            status = Status.Failed;
        }
        uint256 bal = token.balanceOf(address(this));
        require(bal > 0, "no tokens to withdraw");
        token.safeTransfer(creator, bal);
        emit CreatorTokensWithdrawn(creator, bal);
    }

    // ── Core: emergency refund (H-01 equivalent for presale) ─────────────────────
    /**
     * @notice Anyone can call this after FINALIZE_GRACE_PERIOD past endTime if the
     *         presale was never finalized or cancelled. Permanently cancels the presale
     *         so all contributors can use refund(), and immediately refunds the caller.
     */
    function emergencyRefund() external override nonReentrant {
        require(block.timestamp > endTime + FINALIZE_GRACE_PERIOD, "grace period not over");
        require(
            status == Status.Active  ||
            status == Status.Pending ||
            status == Status.Filled,
            "sale already resolved"
        );

        status = Status.Cancelled;
        emit EmergencyCancelled(msg.sender);

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
        if (block.timestamp > endTime && totalRaised < softcap) return true;
        if (block.timestamp > endTime + FINALIZE_GRACE_PERIOD &&
            totalRaised >= softcap &&
            status != Status.Finalized &&
            status != Status.Cancelled) return true;
        return false;
    }

    // ── Core: cancel ───────────────────────────────────────────────────────────
    function cancelPresale() external override onlyCreator {
        require(
            status == Status.Pending ||
            status == Status.Active  ||
            status == Status.Filled,
            "cannot cancel"
        );
        status = Status.Cancelled;
        emit Cancelled();
    }

    // ── View functions ─────────────────────────────────────────────────────────
    function getContribution(address investor) external view override returns (uint256) {
        return contributions[investor];
    }

    function getClaimableTokens(address investor) public view override returns (uint256) {
        if (status != Status.Finalized) return 0;

        uint256 totalTokens = (contributions[investor] * presaleRate) / 1e18;
        if (totalTokens == 0) return 0;

        uint256 tgeAmount = (totalTokens * vestingPercentTGE) / PERCENT_DENOMINATOR;
        uint256 remaining = totalTokens - tgeAmount;

        uint256 vestedAmount;
        if (vestingDurationDays == 0) {
            vestedAmount = remaining;
        } else {
            uint256 elapsed  = block.timestamp - finalizedAt;
            uint256 duration = vestingDurationDays * 1 days;
            if (elapsed >= duration) {
                vestedAmount = remaining;
            } else {
                vestedAmount = (remaining * elapsed) / duration;
            }
        }

        uint256 unlocked       = tgeAmount + vestedAmount;
        uint256 alreadyClaimed = tokensClaimed[investor];
        return unlocked > alreadyClaimed ? unlocked - alreadyClaimed : 0;
    }

    function getTotalRaised()      external view override returns (uint256) { return totalRaised; }
    function getParticipantCount() external view override returns (uint256) { return participantCount; }
    function getStatus()           external view override returns (Status)  { return status; }

    function isPresaleActive() external view override returns (bool) {
        return (
            (status == Status.Pending || status == Status.Active) &&
            block.timestamp >= startTime &&
            block.timestamp <= endTime
        );
    }

    receive() external payable {}
}

// ── Minimal DEX interfaces ─────────────────────────────────────────────────────
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

interface IMoonsaleFactory {
    function lockLiquidity(address lpToken, uint256 amount, uint256 unlockTime, address owner) external;
    function penaltyPercent() external view returns (uint256);
    function penaltyReceiver() external view returns (address);
}
