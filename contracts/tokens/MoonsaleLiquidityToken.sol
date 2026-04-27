// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH()    external pure returns (address);

    function addLiquidityETH(
        address token,
        uint    amountTokenDesired,
        uint    amountTokenMin,
        uint    amountETHMin,
        address to,
        uint    deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint    amountIn,
        uint    amountOutMin,
        address[] calldata path,
        address to,
        uint    deadline
    ) external;

    // H-02: needed to compute slippage floor
    function getAmountsOut(uint amountIn, address[] calldata path)
        external view returns (uint[] memory amounts);
}

/// @title  MoonsaleLiquidityToken
/// @notice ERC-20 with auto-liquidity and marketing fee on every transfer.
///         Deployed by MoonsaleTokenFactory — ownership transferred to creator on deploy.
contract MoonsaleLiquidityToken is ERC20, Ownable, ReentrancyGuard {

    // H-01: LP tokens are permanently burned rather than sent to owner
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 private _dec;

    // ── Fees (basis points, 100 = 1%) ─────────────────────────────────────────
    uint16 public liquidityFee;
    uint16 public marketingFee;
    uint16 public totalFee;

    // ── Slippage floor (H-02) ─────────────────────────────────────────────────
    uint16 public maxSlippageBps = 300; // 3% default, owner-settable 100–500

    // ── Limits ────────────────────────────────────────────────────────────────
    uint256 public maxTxAmount;
    uint256 public maxWalletAmount;
    uint256 public immutable minLimitAmount;  // I-02: 0.1% of supply, never changes
    uint256 public immutable maxSwapThreshold; // L-R2: 1% of supply, never changes

    // ── Addresses ─────────────────────────────────────────────────────────────
    address public marketingWallet;
    address public pendingMarketingWallet;      // L-02: two-step rotation
    uint256 public pendingMarketingWalletTime;  // L-02

    IUniswapV2Router02 public immutable router;
    address            public immutable pair;

    // ── Swap-and-liquify ──────────────────────────────────────────────────────
    uint256 public swapThreshold;
    bool    public swapEnabled = true;
    bool    private _inSwap;

    // ── Pending ETH tracking (M-03) ───────────────────────────────────────────
    uint256 public pendingLiqETH;       // ETH from failed addLiquidityETH calls
    uint256 public pendingMarketingETH; // ETH from failed marketing sends

    mapping(address => bool) public isExcludedFromFee;
    mapping(address => bool) public isExcludedFromLimit;

    // ── Events ────────────────────────────────────────────────────────────────
    event LiquidityAdded(uint256 indexed tokenAmount, uint256 indexed ethAmount);
    event MarketingFeeSent(address indexed to, uint256 ethAmount);
    event MarketingFeePending(address indexed to, uint256 amount);
    event SwapFailed(uint256 tokens);
    event FeesUpdated(uint16 indexed liquidityFee, uint16 indexed marketingFee);
    event SwapThresholdUpdated(uint256 newThreshold);
    event MaxSlippageUpdated(uint16 bps);
    event MaxTxAmountUpdated(uint256 newAmount);
    event MaxWalletAmountUpdated(uint256 newAmount);
    event MarketingWalletProposed(address indexed wallet);
    event MarketingWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event SwapEnabledUpdated(bool enabled);
    event FeeExclusionUpdated(address indexed account, bool excluded);
    event LimitExclusionUpdated(address indexed account, bool excluded);
    event ETHRescued(address indexed to, uint256 amount);

    modifier lockSwap() {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    constructor(
        string memory  name_,
        string memory  symbol_,
        uint8          decimals_,
        uint256        totalSupply_,
        uint16         liquidityFee_,
        uint16         marketingFee_,
        uint256        maxTxBps_,
        uint256        maxWalletBps_,
        address        marketingWallet_,
        address        router_,
        address        owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        // L-04: validate decimals and supply
        require(decimals_    <= 18, "MoonsaleLiqToken: decimals > 18");
        require(totalSupply_ >  0,  "MoonsaleLiqToken: zero supply");
        // fee caps
        require(marketingFee_                 <= 1000, "MoonsaleLiqToken: marketing fee > 10%");
        require(liquidityFee_ + marketingFee_ <= 2500, "MoonsaleLiqToken: fee > 25%");
        // M-05: both lower and upper bound on limit params
        require(maxTxBps_     >= 10 && maxTxBps_     <= 10000, "MoonsaleLiqToken: maxTxBps out of range");
        require(maxWalletBps_ >= 10 && maxWalletBps_ <= 10000, "MoonsaleLiqToken: maxWalletBps out of range");
        require(marketingWallet_ != address(0), "MoonsaleLiqToken: zero marketing wallet");
        require(router_          != address(0), "MoonsaleLiqToken: zero router");

        _dec            = decimals_;
        liquidityFee    = liquidityFee_;
        marketingFee    = marketingFee_;
        totalFee        = liquidityFee_ + marketingFee_;
        marketingWallet = marketingWallet_;

        uint256 supply  = totalSupply_ * 10 ** decimals_;
        maxTxAmount     = supply * maxTxBps_     / 10000;
        maxWalletAmount = supply * maxWalletBps_ / 10000;
        swapThreshold    = supply / 1000;
        minLimitAmount   = supply / 1000;  // I-02: immutable, avoids repeated totalSupply() reads
        maxSwapThreshold = supply / 100;   // L-R2: immutable upper bound for setSwapThreshold

        router = IUniswapV2Router02(router_);
        pair   = IUniswapV2Factory(router.factory()).createPair(address(this), router.WETH());

        isExcludedFromFee[owner_]        = true;
        isExcludedFromFee[address(this)] = true;

        isExcludedFromLimit[owner_]        = true;
        isExcludedFromLimit[address(this)] = true;
        isExcludedFromLimit[pair]          = true;

        _mint(owner_, supply);
    }

    // ── ERC-20 overrides ──────────────────────────────────────────────────────

    function decimals() public view override returns (uint8) { return _dec; }

    receive() external payable {}

    function _update(address from, address to, uint256 amount) internal override {
        bool takeFee = !_inSwap
            && from != address(0) && to != address(0)
            && !isExcludedFromFee[from] && !isExcludedFromFee[to];

        if (!takeFee) {
            super._update(from, to, amount);
            return;
        }

        if (!isExcludedFromLimit[from]) {
            require(amount <= maxTxAmount, "MoonsaleLiqToken: exceeds maxTx");
        }
        if (to != pair && !isExcludedFromLimit[to]) {
            require(balanceOf(to) + amount <= maxWalletAmount, "MoonsaleLiqToken: exceeds maxWallet");
        }

        if (to == pair && swapEnabled && balanceOf(address(this)) >= swapThreshold) {
            _swapAndLiquify(swapThreshold);
        }

        uint256 feeAmount = totalFee > 0 ? (amount * totalFee) / 10000 : 0;
        if (feeAmount > 0) {
            super._update(from, address(this), feeAmount);
        }
        super._update(from, to, amount - feeAmount);
    }

    // ── Swap-and-liquify logic ────────────────────────────────────────────────

    function _swapAndLiquify(uint256 tokens) private lockSwap nonReentrant {
        if (totalFee == 0) return;

        uint256 liqTokenHalf = (tokens * liquidityFee) / totalFee / 2;
        uint256 swapTokens   = tokens - liqTokenHalf;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        _approve(address(this), address(router), tokens);

        // H-02: derive slippage floor from live on-chain price
        uint256 amountOutMin;
        try router.getAmountsOut(swapTokens, path) returns (uint256[] memory amounts) {
            amountOutMin = amounts[1] * (10000 - maxSlippageBps) / 10000;
        } catch {
            return;
        }

        // M-03: exclude pending ETH so it doesn't inflate ethGained
        uint256 ethBefore = address(this).balance - (pendingLiqETH + pendingMarketingETH);

        // H-03: wrap swap in try/catch — failure must not revert the user's transfer
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapTokens, amountOutMin, path, address(this), block.timestamp + 300
        ) {} catch {
            emit SwapFailed(swapTokens);
            return;
        }

        uint256 ethGained = address(this).balance - (pendingLiqETH + pendingMarketingETH) - ethBefore;
        if (ethGained == 0) return;

        uint256 ethForLiq = liqTokenHalf > 0 && swapTokens > 0
            ? (ethGained * liqTokenHalf) / swapTokens
            : 0;

        // H-01: LP tokens burned to DEAD
        _addLiquidity(liqTokenHalf, ethForLiq);
        // L-03: track failed marketing sends for retry
        _sendMarketing(ethGained - ethForLiq);
    }

    function _addLiquidity(uint256 liqTokenHalf, uint256 ethForLiq) private {
        if (liqTokenHalf == 0 || ethForLiq == 0) return;
        uint256 liqMin  = liqTokenHalf * 9800 / 10000;
        uint256 ethMin  = ethForLiq    * 9800 / 10000;
        uint256 balPre  = address(this).balance; // I-R1: snapshot before call
        try router.addLiquidityETH{value: ethForLiq}(
            address(this), liqTokenHalf, liqMin, ethMin, DEAD, block.timestamp + 300
        ) returns (uint256 addedTokens, uint256 addedEth, uint256) {
            emit LiquidityAdded(addedTokens, addedEth);
            // I-R1: router refunds unused ETH — track it so rescueETH can't sweep it
            uint256 refund = address(this).balance - (balPre - ethForLiq);
            if (refund > 0) pendingLiqETH += refund;
        } catch {
            pendingLiqETH += ethForLiq; // M-03
        }
    }

    function _sendMarketing(uint256 amount) private {
        if (amount == 0 || marketingWallet == address(0)) return;
        (bool sent,) = marketingWallet.call{value: amount}("");
        if (sent) {
            emit MarketingFeeSent(marketingWallet, amount);
        } else {
            pendingMarketingETH += amount; // M-03
            emit MarketingFeePending(marketingWallet, amount);
        }
    }

    // ── Owner controls ────────────────────────────────────────────────────────

    function setFees(uint16 liqFee, uint16 mktFee) external onlyOwner {
        require(liqFee + mktFee <= 2500, "MoonsaleLiqToken: fee > 25%");
        require(mktFee          <= 1000, "MoonsaleLiqToken: marketing fee > 10%"); // M-01
        liquidityFee = liqFee;
        marketingFee = mktFee;
        totalFee     = liqFee + mktFee;
        emit FeesUpdated(liqFee, mktFee);
    }

    function setMaxTxAmount(uint256 amount) external onlyOwner {
        require(amount >= minLimitAmount, "MoonsaleLiqToken: maxTx < 0.1%");
        maxTxAmount = amount;
        emit MaxTxAmountUpdated(amount);
    }

    function setMaxWalletAmount(uint256 amount) external onlyOwner {
        require(amount >= minLimitAmount, "MoonsaleLiqToken: maxWallet < 0.1%");
        maxWalletAmount = amount;
        emit MaxWalletAmountUpdated(amount);
    }

    // L-02: two-step marketing wallet rotation with 48-hour timelock
    function proposeMarketingWallet(address wallet) external onlyOwner {
        require(wallet != address(0), "zero address");
        pendingMarketingWallet     = wallet;
        pendingMarketingWalletTime = block.timestamp + 48 hours;
        emit MarketingWalletProposed(wallet);
    }

    function confirmMarketingWallet() external onlyOwner nonReentrant {
        require(pendingMarketingWallet != address(0), "no pending wallet");
        require(block.timestamp >= pendingMarketingWalletTime, "timelock active");
        address old            = marketingWallet;
        marketingWallet        = pendingMarketingWallet;
        pendingMarketingWallet = address(0);
        pendingMarketingWalletTime = 0;
        emit MarketingWalletUpdated(old, marketingWallet);
        // L-R1: auto-deliver any stuck pending ETH to the newly confirmed wallet
        uint256 pending = pendingMarketingETH;
        if (pending > 0) {
            pendingMarketingETH = 0;
            (bool sent,) = marketingWallet.call{value: pending}("");
            if (sent) {
                emit MarketingFeeSent(marketingWallet, pending);
            } else {
                pendingMarketingETH = pending;
            }
        }
    }

    // M-02: bounded swap threshold (0.001% – 1% of supply)
    // L-R2: use immutables instead of live totalSupply() reads
    function setSwapThreshold(uint256 threshold) external onlyOwner {
        require(
            threshold >= minLimitAmount / 100 && threshold <= maxSwapThreshold,
            "MoonsaleLiqToken: threshold out of range"
        );
        swapThreshold = threshold;
        emit SwapThresholdUpdated(threshold);
    }

    function setSwapEnabled(bool enabled) external onlyOwner {
        swapEnabled = enabled;
        emit SwapEnabledUpdated(enabled);
    }

    // H-02: slippage tolerance, bounded 1%–5%
    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        require(bps >= 100 && bps <= 500, "MoonsaleLiqToken: slippage out of range");
        maxSlippageBps = bps;
        emit MaxSlippageUpdated(bps);
    }

    function excludeFromFee(address account, bool excluded) external onlyOwner {
        require(account != address(0), "zero address"); // I-01
        isExcludedFromFee[account] = excluded;
        emit FeeExclusionUpdated(account, excluded);
    }

    function excludeFromLimit(address account, bool excluded) external onlyOwner {
        require(account != address(0), "zero address"); // I-01
        isExcludedFromLimit[account] = excluded;
        emit LimitExclusionUpdated(account, excluded);
    }

    // M-03: rescue only ETH above pending amounts — cannot sweep earmarked funds
    function rescueETH() external onlyOwner nonReentrant {
        uint256 reserved = pendingLiqETH + pendingMarketingETH;
        require(address(this).balance > reserved, "nothing to rescue");
        uint256 amount = address(this).balance - reserved;
        (bool sent,) = owner().call{value: amount}("");
        require(sent, "ETH rescue failed");
        emit ETHRescued(owner(), amount);
    }

    // L-03: retry failed marketing payment
    function claimPendingMarketing() external nonReentrant {
        uint256 amount = pendingMarketingETH;
        require(amount > 0, "nothing pending");
        pendingMarketingETH = 0;
        (bool sent,) = marketingWallet.call{value: amount}("");
        require(sent, "claim failed");
        emit MarketingFeeSent(marketingWallet, amount);
    }

    // M-03: owner can reclaim stuck liq ETH if addLiquidityETH persistently fails
    function claimPendingLiq() external onlyOwner nonReentrant {
        uint256 amount = pendingLiqETH;
        require(amount > 0, "nothing pending");
        pendingLiqETH = 0;
        (bool sent,) = owner().call{value: amount}("");
        require(sent, "claim failed");
        emit ETHRescued(owner(), amount);
    }
}
