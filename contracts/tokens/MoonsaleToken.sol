// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/// @title MoonsaleToken
/// @notice Standard BEP-20/ERC-20 token with optional mint and burn capabilities.
///         Deployed by MoonsaleTokenFactory — ownership transferred to creator on deploy.
contract MoonsaleToken is ERC20, Ownable {

    // L-01: immutable — set once at deploy, read for free thereafter
    uint8   private immutable _dec;
    bool    public  immutable isMintable;  // capability declaration
    bool    public  immutable isBurnable;

    // H-01: hard supply cap enforced on every mint call
    uint256 public immutable maxSupply;

    // M-01: mutable active flag — owner can permanently disable minting
    bool public mintingActive;

    // ── Events ────────────────────────────────────────────────────────────────
    event TokensMinted(address indexed to,   uint256 amount, uint256 newTotalSupply); // L-02
    event TokensBurned(address indexed from, uint256 amount, uint256 newTotalSupply); // L-02
    event MintingDisabled();                                                           // M-01

    constructor(
        string memory name_,
        string memory symbol_,
        uint8         decimals_,
        uint256       totalSupply_,
        uint256       maxSupply_,    // raw token units (pre-scaling); 0 = cap at initial supply
        bool          mintable_,
        bool          burnable_,
        address       owner_
    ) ERC20(name_, symbol_) Ownable(owner_) {
        // M-02: reject decimals outside conventional ERC-20 range
        require(decimals_    <= 18, "MoonsaleToken: decimals > 18");
        // M-03: reject zero supply unless token is mintable (can mint later)
        require(totalSupply_ > 0 || mintable_, "MoonsaleToken: zero supply and not mintable");
        // I-R1: mintable tokens must declare an explicit cap; 0 sentinel means "cap at initial supply"
        //       which makes future minting impossible — contradictory and likely a user error
        require(!mintable_ || maxSupply_ > 0, "MoonsaleToken: mintable requires explicit maxSupply");

        uint256 supply = totalSupply_ * 10 ** decimals_;

        // H-01: derive cap — 0 means "cap at initial supply" (no inflation allowed)
        uint256 cap = maxSupply_ == 0 ? supply : maxSupply_ * 10 ** decimals_;
        require(cap >= supply, "MoonsaleToken: maxSupply < totalSupply");

        _dec          = decimals_;
        isMintable    = mintable_;
        isBurnable    = burnable_;
        maxSupply     = cap;
        mintingActive = mintable_; // starts active iff capability was granted

        if (supply > 0) {
            _mint(owner_, supply);
        }
    }

    function decimals() public view virtual override returns (uint8) { return _dec; }

    /// @notice Mint additional tokens. Owner only, only while minting is active, only up to cap.
    function mint(address to, uint256 amount) external onlyOwner {
        require(mintingActive,             "MoonsaleToken: minting disabled");
        require(to != address(0),          "MoonsaleToken: zero recipient"); // L-03
        require(amount > 0,                "MoonsaleToken: zero amount");    // L-03
        require(totalSupply() + amount <= maxSupply, "MoonsaleToken: cap exceeded"); // H-01
        _mint(to, amount);
        emit TokensMinted(to, amount, totalSupply()); // L-02
    }

    /// @notice Permanently disable minting. One-way — cannot be re-enabled.
    function disableMinting() external onlyOwner { // M-01
        require(mintingActive, "MoonsaleToken: already disabled");
        mintingActive = false;
        emit MintingDisabled();
    }

    /// @notice Burn tokens from caller's balance. Only if burnable.
    function burn(uint256 amount) external {
        require(isBurnable, "MoonsaleToken: not burnable");
        require(amount > 0, "MoonsaleToken: zero amount"); // L-03
        _burn(msg.sender, amount);
        emit TokensBurned(msg.sender, amount, totalSupply()); // L-02
    }

    /// @notice Burn tokens from another account using caller's allowance. Only if burnable. (I-R2)
    function burnFrom(address account, uint256 amount) external {
        require(isBurnable, "MoonsaleToken: not burnable");
        require(amount > 0, "MoonsaleToken: zero amount"); // L-03
        _spendAllowance(account, msg.sender, amount);
        _burn(account, amount);
        emit TokensBurned(account, amount, totalSupply()); // L-02
    }
}
