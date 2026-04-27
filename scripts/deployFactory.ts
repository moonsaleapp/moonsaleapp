import { ethers, network, run } from "hardhat";

// DEX V2 routers per network
const DEX_ROUTERS: Record<string, string> = {
  // BNB Chain — PancakeSwap V2
  bscTestnet: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1",
  bsc:        "0x10ED43C718714eb63d5aA57B78B54704E256024E",
  // Ethereum — Uniswap V2
  sepolia:    "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",  // Uniswap V2 (placeholder — finalize not supported on Sepolia)
  ethereum:   "0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D",  // Uniswap V2 mainnet
};

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "BNB"
  );

  const dexRouter = DEX_ROUTERS[chainName];
  if (!dexRouter) throw new Error(`No DEX router configured for ${chainName}`);

  const feeRecipient       = deployer.address;
  const platformFeePercent = 200n;  // 2%
  const minLockDays        = 30n;

  // ── Step 1: Deploy MoonsalePresale implementation (no constructor args) ──────
  console.log("\n[1/2] Deploying MoonsalePresale implementation...");
  const Presale = await ethers.getContractFactory("MoonsalePresale");
  const presaleImpl = await Presale.deploy();
  await presaleImpl.waitForDeployment();
  const presaleImplAddress = await presaleImpl.getAddress();
  console.log("  MoonsalePresale (impl):", presaleImplAddress);

  // Wait for confirmations
  const implTx = presaleImpl.deploymentTransaction();
  if (implTx) await implTx.wait(3);

  // ── Step 2: Deploy MoonsaleFactory with implementation address ───────────────
  console.log("\n[2/2] Deploying MoonsaleFactory...");
  console.log("  presaleImpl:         ", presaleImplAddress);
  console.log("  dexRouter:           ", dexRouter);
  console.log("  feeRecipient:        ", feeRecipient);
  console.log("  platformFeePercent:  ", platformFeePercent.toString(), "(2%)");
  console.log("  minLiquidityLockDays:", minLockDays.toString());

  const Factory = await ethers.getContractFactory("MoonsaleFactory");
  const factory = await Factory.deploy(
    presaleImplAddress,
    dexRouter,
    feeRecipient,
    platformFeePercent,
    minLockDays
  );
  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();
  console.log("  MoonsaleFactory:     ", factoryAddress);

  // Wait for confirmations before verifying
  console.log("\nWaiting for block confirmations...");
  const factoryTx = factory.deploymentTransaction();
  if (factoryTx) await factoryTx.wait(5);

  // ── Verify ────────────────────────────────────────────────────────────────────
  console.log("\nVerifying MoonsalePresale implementation...");
  try {
    await run("verify:verify", { address: presaleImplAddress, constructorArguments: [] });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  console.log("\nVerifying MoonsaleFactory...");
  try {
    await run("verify:verify", {
      address: factoryAddress,
      constructorArguments: [presaleImplAddress, dexRouter, feeRecipient, platformFeePercent, minLockDays],
    });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  const envSuffix: Record<string, string> = { bscTestnet: "BSCTESTNET", bsc: "BSC", sepolia: "SEPOLIA", ethereum: "ETH" };
  const envKey = `NEXT_PUBLIC_FACTORY_ADDRESS_${envSuffix[chainName] ?? chainName.toUpperCase()}`;
  console.log(`\n✓ Add to your .env.local:`);
  console.log(`  ${envKey}=${factoryAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
