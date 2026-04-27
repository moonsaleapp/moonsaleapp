// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MoonsaleTokenLock
 * @notice Simple ERC20 token time-lock. Anyone can create a lock for any token.
 *         Tokens are fully released after the unlock timestamp.
 */
contract MoonsaleTokenLock is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Lock {
        address token;
        address owner;
        uint256 amount;
        uint256 unlockTime;
        bool    withdrawn;
        string  description;   // optional label e.g. "Team Allocation"
    }

    uint256 public constant MAX_FEE = 10 ether;  // L-01: cap prevents accidental/malicious abuse

    uint256 public lockCount;
    mapping(uint256 => Lock) public locks;

    // owner => list of lock IDs
    mapping(address => uint256[]) private _ownerLocks;
    // token => list of lock IDs
    mapping(address => uint256[]) private _tokenLocks;

    uint256 public fee;           // fee in native token (BNB)
    address public feeRecipient;
    address public owner;
    bool    public creationPaused; // L-05: emergency pause for new locks

    event LockCreated(
        uint256 indexed lockId,
        address indexed token,
        address indexed owner,
        uint256 amount,
        uint256 unlockTime
    );
    event Withdrawn(uint256 indexed lockId, address indexed owner, uint256 amount);
    event LockExtended(uint256 indexed lockId, uint256 newUnlockTime);
    event FeeUpdated(uint256 newFee);
    event CreationPausedUpdated(bool paused);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _fee, address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient"); // L-02
        require(_fee <= MAX_FEE,             "Fee too high");          // L-01
        owner        = msg.sender;
        fee          = _fee;
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Create a new token lock.
     * @param token       ERC20 token to lock
     * @param amount      Amount of tokens (in token's smallest unit)
     * @param unlockTime  Unix timestamp when tokens become withdrawable
     * @param description Optional label
     */
    function createLock(
        address token,
        uint256 amount,
        uint256 unlockTime,
        string calldata description
    ) external payable nonReentrant returns (uint256 lockId) {
        require(!creationPaused,              "Lock creation paused"); // L-05
        require(msg.value >= fee,             "Insufficient fee");
        require(amount > 0,                   "Amount must be > 0");
        require(unlockTime > block.timestamp, "Unlock time must be in future");
        require(token != address(0),          "Invalid token");

        // Forward exactly fee; refund any excess (H-01)
        if (fee > 0) {
            (bool sent, ) = feeRecipient.call{value: fee}("");
            require(sent, "Fee transfer failed");
        }
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool r, ) = msg.sender.call{value: excess}("");
            require(r, "Excess refund failed");
        }

        // M-02: snapshot balance before/after to handle fee-on-transfer tokens
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        require(received > 0, "No tokens received");

        lockId = lockCount++;
        locks[lockId] = Lock({
            token:       token,
            owner:       msg.sender,
            amount:      received,   // record what was actually received, not what was requested
            unlockTime:  unlockTime,
            withdrawn:   false,
            description: description
        });

        _ownerLocks[msg.sender].push(lockId);
        _tokenLocks[token].push(lockId);

        emit LockCreated(lockId, token, msg.sender, received, unlockTime);
    }

    /**
     * @notice Withdraw tokens after unlock time. Never paused -- users can always reclaim.
     */
    function withdraw(uint256 lockId) external nonReentrant {
        Lock storage l = locks[lockId];
        require(l.owner == msg.sender,           "Not lock owner");
        require(!l.withdrawn,                    "Already withdrawn");
        require(block.timestamp >= l.unlockTime, "Still locked");

        l.withdrawn = true;
        IERC20(l.token).safeTransfer(msg.sender, l.amount);

        emit Withdrawn(lockId, msg.sender, l.amount);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    function getLocksByOwner(address _owner) external view returns (uint256[] memory) {
        return _ownerLocks[_owner];
    }

    function getLocksByToken(address token) external view returns (uint256[] memory) {
        return _tokenLocks[token];
    }

    // L-04: paginated versions to avoid unbounded RPC calls
    function getLocksByOwnerPaginated(address _owner, uint256 offset, uint256 limit)
        external view returns (uint256[] memory ids, uint256 total)
    {
        uint256[] storage all = _ownerLocks[_owner];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = all[i];
        }
    }

    function getLocksByTokenPaginated(address token, uint256 offset, uint256 limit)
        external view returns (uint256[] memory ids, uint256 total)
    {
        uint256[] storage all = _tokenLocks[token];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            ids[i - offset] = all[i];
        }
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Fee too high"); // L-01
        fee = _fee;
        emit FeeUpdated(_fee);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid address");
        feeRecipient = _recipient;
    }

    // L-05: only gates createLock, never withdraw
    function setCreationPaused(bool _paused) external onlyOwner {
        creationPaused = _paused;
        emit CreationPausedUpdated(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        owner = newOwner;
    }

    function extendLock(uint256 lockId, uint256 newUnlockTime) external nonReentrant {
        Lock storage l = locks[lockId];
        require(l.owner == msg.sender,                          "Not lock owner");
        require(!l.withdrawn,                                   "Already withdrawn");
        require(newUnlockTime > l.unlockTime,                   "Must be later than current unlock");
        require(newUnlockTime <= block.timestamp + 3650 days,   "Exceeds max lock duration");

        l.unlockTime = newUnlockTime;
        emit LockExtended(lockId, newUnlockTime);
    }

    function sweepStuckETH() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "Nothing to sweep");
        (bool ok, ) = feeRecipient.call{value: bal}("");
        require(ok, "Sweep failed");
    }
}
