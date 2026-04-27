// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./MoonsaleToken.sol";
import "./MoonsaleLiquidityToken.sol";

/// @title MoonsaleTokenFactory
/// @notice Factory contract for deploying standard BEP-20 tokens on BNB Chain.
///         Creation fees accumulate in the contract and are claimed via withdrawFees().
contract MoonsaleTokenFactory is Ownable, ReentrancyGuard {

    uint256 public constant maxCreationFee = 1 ether; // L-03: on-chain ceiling, owner cannot exceed
    uint256 public creationFee;
    address public feeRecipient;
    uint256 public pendingFees; // L-02: pull pattern — fees accumulate here, claimed via withdrawFees()

    event TokenCreated(
        address indexed token,
        address indexed creator,
        string  name,
        string  symbol,
        uint8   decimals,
        uint256 totalSupply,
        uint256 maxSupply,  // I-01
        bool    mintable,
        bool    burnable
    );

    event LiquidityTokenCreated(
        address indexed token,
        address indexed creator,
        string  name,
        string  symbol,
        uint8   decimals,
        uint256 totalSupply,
        uint16  liquidityFee,  // I-01
        uint16  marketingFee   // I-01
    );

    event FeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    constructor(uint256 creationFee_, address feeRecipient_) Ownable(msg.sender) {
        require(feeRecipient_ != address(0), "MoonsaleTokenFactory: zero recipient"); // L-01
        require(creationFee_ <= maxCreationFee, "MoonsaleTokenFactory: fee too high"); // L-03
        creationFee  = creationFee_;
        feeRecipient = feeRecipient_;
        emit FeeUpdated(0, creationFee_);                    // I-02
        emit FeeRecipientUpdated(address(0), feeRecipient_); // I-02
    }

    /// @notice Deploy a standard token. Caller pays exactly creationFee and receives full supply + ownership.
    function createToken(
        string  calldata name,
        string  calldata symbol,
        uint8            decimals_,
        uint256          totalSupply,
        uint256          maxSupply_,
        bool             mintable,
        bool             burnable
    ) external payable nonReentrant returns (address tokenAddress) { // M-02
        require(msg.value == creationFee,     "MoonsaleTokenFactory: incorrect fee"); // M-01
        require(bytes(name).length   > 0,     "MoonsaleTokenFactory: empty name");
        require(bytes(symbol).length > 0,     "MoonsaleTokenFactory: empty symbol");
        require(totalSupply > 0 || mintable,  "MoonsaleTokenFactory: zero supply and not mintable");
        require(decimals_           <= 18,    "MoonsaleTokenFactory: decimals > 18");

        tokenAddress = address(new MoonsaleToken(
            name, symbol, decimals_, totalSupply, maxSupply_, mintable, burnable, msg.sender
        ));

        pendingFees += msg.value; // L-02

        emit TokenCreated(tokenAddress, msg.sender, name, symbol, decimals_, totalSupply, maxSupply_, mintable, burnable); // I-01
    }

    /// @notice Deploy a Liquidity Generator token. Caller pays exactly creationFee and receives full supply + ownership.
    function createLiquidityToken(
        string  calldata name,
        string  calldata symbol,
        uint8            decimals_,
        uint256          totalSupply,
        uint16           liquidityFee_,
        uint16           marketingFee_,
        uint256          maxTxBps_,
        uint256          maxWalletBps_,
        address          marketingWallet_,
        address          router_
    ) external payable nonReentrant returns (address tokenAddress) { // M-02
        require(msg.value == creationFee,       "MoonsaleTokenFactory: incorrect fee"); // M-01
        require(bytes(name).length   > 0,       "MoonsaleTokenFactory: empty name");
        require(bytes(symbol).length > 0,       "MoonsaleTokenFactory: empty symbol");
        require(totalSupply          > 0,       "MoonsaleTokenFactory: zero supply");
        require(decimals_           <= 18,      "MoonsaleTokenFactory: decimals > 18");
        require(marketingWallet_ != address(0), "MoonsaleTokenFactory: zero marketing wallet");
        require(router_          != address(0), "MoonsaleTokenFactory: zero router");

        tokenAddress = address(new MoonsaleLiquidityToken(
            name, symbol, decimals_, totalSupply,
            liquidityFee_, marketingFee_,
            maxTxBps_, maxWalletBps_,
            marketingWallet_, router_, msg.sender
        ));

        pendingFees += msg.value; // L-02

        emit LiquidityTokenCreated(
            tokenAddress, msg.sender, name, symbol, decimals_, totalSupply,
            liquidityFee_, marketingFee_ // I-01
        );
    }

    /// @notice Transfer all accumulated fees to feeRecipient. Callable by anyone.
    function withdrawFees() external nonReentrant {
        uint256 amount = pendingFees;
        require(amount > 0, "MoonsaleTokenFactory: no fees");
        pendingFees = 0;
        (bool sent, ) = feeRecipient.call{value: amount}("");
        require(sent, "MoonsaleTokenFactory: transfer failed");
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function setCreationFee(uint256 fee) external onlyOwner {
        require(fee <= maxCreationFee, "MoonsaleTokenFactory: fee too high"); // L-03
        emit FeeUpdated(creationFee, fee);
        creationFee = fee;
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "MoonsaleTokenFactory: zero address");
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
    }
}
