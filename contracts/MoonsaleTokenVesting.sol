// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title MoonsaleTokenVesting
 * @notice Linear vesting with optional cliff. Anyone can create a vesting
 *         schedule for any ERC20 token for any beneficiary.
 *
 * Vesting model:
 *   - At TGE (startTime):   tgePercent of totalAmount is immediately claimable
 *   - After cliff ends:     remaining tokens vest linearly over vestingDays
 *   - Total claimable at T: tgeAmount + vestedAmount(T)
 */
contract MoonsaleTokenVesting is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct VestingSchedule {
        address token;
        address beneficiary;   // who receives the vested tokens
        address creator;       // who created the schedule
        uint256 totalAmount;
        uint256 tgePercent;    // basis points (e.g. 1000 = 10%)
        uint256 startTime;     // TGE timestamp
        uint256 cliffDays;     // days after startTime before linear vesting begins
        uint256 vestingDays;   // duration of linear vesting after cliff
        uint256 claimed;       // total claimed so far
        string  description;
    }

    uint256 public constant MAX_FEE = 10 ether;

    uint256 public scheduleCount;
    mapping(uint256 => VestingSchedule) public schedules;

    mapping(address => uint256[]) private _beneficiarySchedules;
    mapping(address => uint256[]) private _tokenSchedules;
    mapping(address => uint256[]) private _creatorSchedules;

    uint256 public fee;
    address public feeRecipient;
    address public owner;
    bool    public creationPaused;

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed token,
        address indexed beneficiary,
        address  creator,
        uint256  totalAmount,
        uint256  tgePercent,
        uint256  cliffDays,
        uint256  vestingDays,
        uint256  startTime
    );
    event Claimed(uint256 indexed scheduleId, address indexed beneficiary, uint256 amount);
    event FeeUpdated(uint256 newFee);
    event FeeRecipientUpdated(address indexed newRecipient);
    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event CreationPausedUpdated(bool paused);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor(uint256 _fee, address _feeRecipient) {
        require(_feeRecipient != address(0), "Invalid fee recipient");
        require(_fee <= MAX_FEE,             "Fee too high");
        owner        = msg.sender;
        fee          = _fee;
        feeRecipient = _feeRecipient;
    }

    /**
     * @notice Create a vesting schedule.
     * @param token         ERC20 token to vest
     * @param beneficiary   Address that will receive vested tokens
     * @param totalAmount   Total tokens to vest
     * @param tgePercent    % unlocked at startTime in bps (0-10000). 0 = fully vested linearly.
     * @param startTime     TGE timestamp (must be >= now)
     * @param cliffDays     Days after startTime before linear vesting begins
     * @param vestingDays   Linear vesting duration in days (after cliff)
     * @param description   Optional label
     */
    function createSchedule(
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 tgePercent,
        uint256 startTime,
        uint256 cliffDays,
        uint256 vestingDays,
        string calldata description
    ) external payable nonReentrant returns (uint256 scheduleId) {
        require(!creationPaused,              "Schedule creation paused");
        require(msg.value >= fee,             "Insufficient fee");
        require(totalAmount > 0,              "Amount must be > 0");
        require(startTime >= block.timestamp, "Start must be >= now");
        require(tgePercent <= 10000,          "TGE percent max 100%");
        require(vestingDays > 0 || tgePercent == 10000, "Need vesting days or 100% TGE");
        require(token != address(0),          "Invalid token");
        require(beneficiary != address(0),    "Invalid beneficiary");

        // H-01: forward exactly fee; refund any excess
        if (fee > 0) {
            (bool sent, ) = feeRecipient.call{value: fee}("");
            require(sent, "Fee transfer failed");
        }
        uint256 excess = msg.value - fee;
        if (excess > 0) {
            (bool r, ) = msg.sender.call{value: excess}("");
            require(r, "Excess refund failed");
        }

        // M-02: balance snapshot to handle fee-on-transfer tokens
        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), totalAmount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        require(received > 0, "No tokens received");

        scheduleId = scheduleCount++;
        schedules[scheduleId] = VestingSchedule({
            token:       token,
            beneficiary: beneficiary,
            creator:     msg.sender,
            totalAmount: received,
            tgePercent:  tgePercent,
            startTime:   startTime,
            cliffDays:   cliffDays,
            vestingDays: vestingDays,
            claimed:     0,
            description: description
        });

        _beneficiarySchedules[beneficiary].push(scheduleId);
        _tokenSchedules[token].push(scheduleId);
        _creatorSchedules[msg.sender].push(scheduleId);

        emit ScheduleCreated(scheduleId, token, beneficiary, msg.sender, received, tgePercent, cliffDays, vestingDays, startTime);
    }

    /**
     * @notice Claim all currently vested tokens for a schedule.
     */
    function claim(uint256 scheduleId) external nonReentrant {
        VestingSchedule storage s = schedules[scheduleId];
        require(s.beneficiary == msg.sender, "Not beneficiary");

        uint256 claimable = getClaimable(scheduleId);
        require(claimable > 0, "Nothing to claim");

        s.claimed += claimable;
        IERC20(s.token).safeTransfer(msg.sender, claimable);

        emit Claimed(scheduleId, msg.sender, claimable);
    }

    // ── Views ──────────────────────────────────────────────────────────────────

    /**
     * @notice Total vested amount at current time (includes already claimed).
     */
    function getVested(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = schedules[scheduleId];
        if (block.timestamp < s.startTime) return 0;

        uint256 tgeAmount    = (s.totalAmount * s.tgePercent) / 10000;
        uint256 linearAmount = s.totalAmount - tgeAmount;

        if (linearAmount == 0) return s.totalAmount;

        uint256 cliffEnd = s.startTime + (s.cliffDays * 1 days);
        if (block.timestamp < cliffEnd) return tgeAmount;

        uint256 elapsed  = block.timestamp - cliffEnd;
        uint256 duration = s.vestingDays * 1 days;
        if (elapsed >= duration) return s.totalAmount;

        uint256 linearVested = (linearAmount * elapsed) / duration;
        return tgeAmount + linearVested;
    }

    /**
     * @notice Currently claimable (vested minus already claimed).
     */
    function getClaimable(uint256 scheduleId) public view returns (uint256) {
        VestingSchedule storage s = schedules[scheduleId];
        uint256 vested = getVested(scheduleId);
        return vested > s.claimed ? vested - s.claimed : 0;
    }

    function getSchedulesByBeneficiary(address ben) external view returns (uint256[] memory) {
        return _beneficiarySchedules[ben];
    }

    function getSchedulesByToken(address token) external view returns (uint256[] memory) {
        return _tokenSchedules[token];
    }

    function getSchedulesByCreator(address creator) external view returns (uint256[] memory) {
        return _creatorSchedules[creator];
    }

    function getSchedulesByBeneficiaryPaginated(address ben, uint256 offset, uint256 limit)
        external view returns (uint256[] memory ids, uint256 total)
    {
        uint256[] storage all = _beneficiarySchedules[ben];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) ids[i - offset] = all[i];
    }

    function getSchedulesByTokenPaginated(address token, uint256 offset, uint256 limit)
        external view returns (uint256[] memory ids, uint256 total)
    {
        uint256[] storage all = _tokenSchedules[token];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) ids[i - offset] = all[i];
    }

    function getSchedulesByCreatorPaginated(address creator, uint256 offset, uint256 limit)
        external view returns (uint256[] memory ids, uint256 total)
    {
        uint256[] storage all = _creatorSchedules[creator];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        ids = new uint256[](end - offset);
        for (uint256 i = offset; i < end; i++) ids[i - offset] = all[i];
    }

    // ── Admin ──────────────────────────────────────────────────────────────────

    function setFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAX_FEE, "Fee too high");
        fee = _fee;
        emit FeeUpdated(_fee);
    }

    function setFeeRecipient(address _recipient) external onlyOwner {
        require(_recipient != address(0), "Invalid address");
        feeRecipient = _recipient;
        emit FeeRecipientUpdated(_recipient);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setCreationPaused(bool _paused) external onlyOwner {
        creationPaused = _paused;
        emit CreationPausedUpdated(_paused);
    }

    function sweepStuckETH() external onlyOwner nonReentrant {
        uint256 bal = address(this).balance;
        require(bal > 0, "Nothing to sweep");
        (bool ok, ) = feeRecipient.call{value: bal}("");
        require(ok, "Sweep failed");
    }
}
