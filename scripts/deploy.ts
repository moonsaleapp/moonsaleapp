import { ethers, network, run } from "hardhat";

// ── DEX Router addresses per chain ────────────────────────────────────────────
// All Uniswap V2-compatible routers
const DEX_ROUTERS: Record<string, string> = {
  // Testnets
  sepolia:         "0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008", // Uniswap V2 Sepolia
  bscTestnet:      "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // PancakeSwap BSC Testnet
  baseSepolia:     "0x1689E7B1F10000AE47eBfE339a4f69dECd19F602", // Uniswap V3 (use V2 fork on testnet)
  mumbai:          "0x8954AfA98594b838bda56FE4C12a09D7739D179b", // QuickSwap Mumbai
  arbitrumSepolia: "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // Uniswap V2 Arb Sepolia

  // Mainnets
  ethereum:  "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Uniswap V2
  bsc:       "0x10ED43C718714eb63d5aA57B78B54704E256024E", // PancakeSwap V2
  base:      "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // Uniswap V2 on Base
  polygon:   "0xa5E0829CaCEd8fFDD4De3c43696c57F7D7A678ff", // QuickSwap
  arbitrum:  "0x4752ba5DBc23f44D87826276BF6Fd6b1C372aD24", // Uniswap V2 on Arbitrum
};

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying MoonsaleFactory to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "ETH"
  );

  const dexRouter = DEX_ROUTERS[chainName];
  if (!dexRouter) {
    throw new Error(`No DEX router configured for network: ${chainName}`);
  }

  const platformFeePercent   = 200;  // 2%
  const minLiquidityLockDays = 90;   // 90 days minimum

  const Factory = await ethers.getContractFactory("MoonsaleFactory");
  const factory = await Factory.deploy(
    dexRouter,
    deployer.address,   // fee recipient (update this before mainnet)
    platformFeePercent,
    minLiquidityLockDays
  );

  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log(`\nMoonsaleFactory deployed to: ${factoryAddress}`);

  console.log(`\nConfig:`);
  console.log(`  DEX Router:            ${dexRouter}`);
  console.log(`  Platform Fee:          ${platformFeePercent / 100}%`);
  console.log(`  Min Liquidity Lock:    ${minLiquidityLockDays} days`);
  console.log(`  Fee Recipient:         ${deployer.address}`);

  // Wait for a few block confirmations before verifying
  console.log("\nWaiting for block confirmations...");
  const deployTx = factory.deploymentTransaction();
  if (deployTx) {
    await deployTx.wait(5);
  }

  // Verify on block explorer
  console.log("\nVerifying on block explorer...");
  try {
    await run("verify:verify", {
      address: factoryAddress,
      constructorArguments: [
        dexRouter,
        deployer.address,
        platformFeePercent,
        minLiquidityLockDays,
      ],
    });
    console.log("Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) {
      console.log("Already verified.");
    } else {
      console.warn("Verification failed:", err.message);
    }
  }

  console.log(`\n✓ Add to your .env:`);
  console.log(`  NEXT_PUBLIC_FACTORY_ADDRESS_${chainName.toUpperCase()}=${factoryAddress}`);
  console.log(`  NEXT_PUBLIC_CHAIN_ID=${(await ethers.provider.getNetwork()).chainId}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
