import { ethers, network, run } from "hardhat";

const DEX_ROUTERS: Record<string, string> = {
  bscTestnet: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1", // PancakeSwap V2 Testnet
  bsc:        "0x10ED43C718714eb63d5aA57B78B54704E256024E", // PancakeSwap V2 Mainnet
  sepolia:    "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Uniswap V2
  ethereum:   "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D", // Uniswap V2
};

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying Fair Launch Factory to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "native"
  );

  const dexRouter = DEX_ROUTERS[chainName];
  if (!dexRouter) throw new Error(`No DEX router configured for ${chainName}`);

  const feeRecipient       = deployer.address;
  const platformFeePercent = 200n;  // 2%
  const minLockDays        = 30n;

  // Step 1: Deploy MoonsaleFairLaunch implementation
  console.log("\n[1/2] Deploying MoonsaleFairLaunch implementation...");
  const FairLaunch = await ethers.getContractFactory("MoonsaleFairLaunch");
  const fairLaunchImpl = await FairLaunch.deploy();
  await fairLaunchImpl.waitForDeployment();
  const implAddress = await fairLaunchImpl.getAddress();
  console.log("  MoonsaleFairLaunch (impl):", implAddress);

  const implTx = fairLaunchImpl.deploymentTransaction();
  if (implTx) await implTx.wait(3);

  // Step 2: Deploy MoonsaleFairLaunchFactory
  console.log("\n[2/2] Deploying MoonsaleFairLaunchFactory...");
  console.log("  impl:                ", implAddress);
  console.log("  dexRouter:           ", dexRouter);
  console.log("  feeRecipient:        ", feeRecipient);
  console.log("  platformFeePercent:  ", platformFeePercent.toString(), "(2%)");
  console.log("  minLiquidityLockDays:", minLockDays.toString());

  const Factory = await ethers.getContractFactory("MoonsaleFairLaunchFactory");
  const factory = await Factory.deploy(
    implAddress,
    dexRouter,
    feeRecipient,
    platformFeePercent,
    minLockDays
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("  MoonsaleFairLaunchFactory:", factoryAddress);

  console.log("\nWaiting for block confirmations...");
  const factoryTx = factory.deploymentTransaction();
  if (factoryTx) await factoryTx.wait(5);

  // Verify
  console.log("\nVerifying MoonsaleFairLaunch implementation...");
  try {
    await run("verify:verify", { address: implAddress, constructorArguments: [] });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  console.log("\nVerifying MoonsaleFairLaunchFactory...");
  try {
    await run("verify:verify", {
      address: factoryAddress,
      constructorArguments: [implAddress, dexRouter, feeRecipient, platformFeePercent, minLockDays],
    });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  const envSuffix: Record<string, string> = {
    bscTestnet: "BSCTESTNET", bsc: "BSC", sepolia: "SEPOLIA", ethereum: "ETH",
  };
  const key = `NEXT_PUBLIC_FAIR_LAUNCH_FACTORY_ADDRESS_${envSuffix[chainName] ?? chainName.toUpperCase()}`;
  console.log(`\nDone! Add to .env.local:`);
  console.log(`  ${key}=${factoryAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
