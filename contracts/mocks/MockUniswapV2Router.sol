// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Minimal mock of Uniswap V2 Router for testing.
 *         addLiquidityETH returns mock LP token amounts and stores nothing real.
 */
contract MockUniswapV2Factory {
    mapping(address => mapping(address => address)) public pairs;
    MockLPToken public lpToken;

    constructor() {
        lpToken = new MockLPToken();
    }

    function getPair(address, address) external view returns (address) {
        return address(lpToken);
    }
}

contract MockLPToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}

contract MockUniswapV2Router {
    MockUniswapV2Factory public uniFactory;
    address public WETH;

    constructor() {
        uniFactory = new MockUniswapV2Factory();
        WETH = address(new MockLPToken()); // dummy WETH
    }

    function factory() external view returns (address) {
        return address(uniFactory);
    }

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256, // amountTokenMin
        uint256, // amountETHMin
        address to,
        uint256  // deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        // Pull tokens from caller
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        // Return mock liquidity (= ETH sent for simplicity)
        liquidity = msg.value;
        uniFactory.lpToken().mint(to, liquidity);

        return (amountTokenDesired, msg.value, liquidity);
    }
}
