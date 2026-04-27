// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IMoonsaleFairLaunch {
    enum Status {
        Pending,    // Deployed, waiting for start time
        Active,     // Open for contributions
        Finalized,  // Softcap met, liquidity added, claims open
        Cancelled,  // Creator cancelled or emergency-cancelled after grace period
        Failed      // Ended without reaching softcap
    }

    event Contributed(address indexed investor, uint256 amount);
    event TokensClaimed(address indexed investor, uint256 amount);
    event Refunded(address indexed investor, uint256 amount);
    event ContributionWithdrawn(address indexed investor, uint256 amount, uint256 penalty);
    event Finalized(uint256 totalRaised, uint256 liquidityNative, uint256 platformFee, uint256 investorTokenPool);
    event Cancelled();
    event EmergencyCancelled(address indexed caller);
    event CreatorTokensWithdrawn(address indexed creator, uint256 amount);
    event WhitelistChanged(address indexed addr, bool status);
    event WhitelistToggled(bool enabled);

    function contribute() external payable;
    function claim() external;
    function refund() external;
    function emergencyRefund() external;
    function withdrawContribution() external;
    function finalize() external;
    function cancelFairLaunch() external;
    function withdrawCreatorTokens() external;

    function getContribution(address investor) external view returns (uint256);
    function getClaimableTokens(address investor) external view returns (uint256);
    function getEstimatedTokenPrice() external view returns (uint256);
    function getTotalRaised() external view returns (uint256);
    function getParticipantCount() external view returns (uint256);
    function getStatus() external view returns (Status);
    function isFairLaunchActive() external view returns (bool);
}
