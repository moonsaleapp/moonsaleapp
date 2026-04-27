// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MoonsaleTokenManager
/// @notice Collects a flat management fee for token management actions
///         (mint, burn, transfer ownership, etc.). The actual token call
///         is made directly by the user from the frontend after fee payment.
contract MoonsaleTokenManager is Ownable {
    uint256 public managementFee;
    address public feeRecipient;

    event FeePaid(address indexed user, address indexed token, string action);
    event ManagementFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeeRecipientUpdated(address oldRecipient, address newRecipient);

    constructor(uint256 managementFee_, address feeRecipient_) Ownable(msg.sender) {
        managementFee = managementFee_;
        feeRecipient  = feeRecipient_;
    }

    /// @notice Pay the management fee before executing a token action.
    /// @param token  The token contract address being managed.
    /// @param action Human-readable action name (e.g. "mint", "burn").
    function payFee(address token, string calldata action) external payable {
        require(msg.value >= managementFee, "MoonsaleTokenManager: insufficient fee");
        require(token != address(0),        "MoonsaleTokenManager: zero token address");

        if (msg.value > 0) {
            (bool sent, ) = feeRecipient.call{ value: msg.value }("");
            require(sent, "MoonsaleTokenManager: fee transfer failed");
        }

        emit FeePaid(msg.sender, token, action);
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function setManagementFee(uint256 fee) external onlyOwner {
        emit ManagementFeeUpdated(managementFee, fee);
        managementFee = fee;
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        require(recipient != address(0), "MoonsaleTokenManager: zero address");
        emit FeeRecipientUpdated(feeRecipient, recipient);
        feeRecipient = recipient;
    }
}
