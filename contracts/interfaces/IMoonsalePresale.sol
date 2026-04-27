// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMoonsalePresale {
    // ── Enums ──────────────────────────────────────────────────────────────────
    enum Status {
        Pending,    // Deployed, waiting for start time
        Active,     // Open for contributions
        Filled,     // Hardcap reached
        Finalized,  // Softcap met, liquidity added, claims open
        Cancelled,  // Creator cancelled before start
        Failed      // Ended without reaching softcap → refunds open
    }

    // ── Events ─────────────────────────────────────────────────────────────────
    event TokensPurchased(address indexed investor, uint256 ethAmount, uint256 tokenAmount);
    event TokensClaimed(address indexed investor, uint256 amount);
    event Refunded(address indexed investor, uint256 ethAmount);
    event ContributionWithdrawn(address indexed investor, uint256 amount, uint256 penalty);
    event Finalized(uint256 totalRaised, uint256 liquidityAdded, uint256 platformFee);
    event Cancelled();
    event EmergencyCancelled(address indexed caller);
    event CreatorTokensWithdrawn(address indexed creator, uint256 amount);
    event EmergencyWithdraw(address indexed to, uint256 amount);

    // ── Write ──────────────────────────────────────────────────────────────────
    function contribute() external payable;
    function claim() external;
    function refund() external;
    function emergencyRefund() external;
    function withdrawContribution() external;
    function finalize() external;
    function cancelPresale() external;
    function withdrawCreatorTokens() external;

    // ── Read ───────────────────────────────────────────────────────────────────
    function getContribution(address investor) external view returns (uint256);
    function getClaimableTokens(address investor) external view returns (uint256);
    function getTotalRaised() external view returns (uint256);
    function getParticipantCount() external view returns (uint256);
    function getStatus() external view returns (Status);
    function isPresaleActive() external view returns (bool);
}
