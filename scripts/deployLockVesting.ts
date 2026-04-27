import { ethers, network, run } from "hardhat";

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying TokenLock + TokenVesting to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "BNB"
  );

  const TESTNETS = ["bscTestnet", "sepolia", "baseSepolia", "mumbai", "arbitrumSepolia"];
  const isTestnet = TESTNETS.includes(chainName);
  const feeRecipient = deployer.address;
  // 0.01 BNB on testnet (existing behavior), 0.006 BNB on mainnet
  const lockFee      = ethers.parseEther(isTestnet ? "0.01" : "0.006");
  const vestingFee   = ethers.parseEther(isTestnet ? "0.01" : "0.006");

  // ── Deploy MoonsaleTokenLock ──────────────────────────────────────────────────
  console.log("\n[1/2] Deploying MoonsaleTokenLock...");
  const Lock = await ethers.getContractFactory("MoonsaleTokenLock");
  const lock = await Lock.deploy(lockFee, feeRecipient);
  await lock.waitForDeployment();
  const lockAddress = await lock.getAddress();
  console.log("  MoonsaleTokenLock:", lockAddress);

  const lockTx = lock.deploymentTransaction();
  if (lockTx) await lockTx.wait(3);

  // ── Deploy MoonsaleTokenVesting ───────────────────────────────────────────────
  console.log("\n[2/2] Deploying MoonsaleTokenVesting...");
  const Vesting = await ethers.getContractFactory("MoonsaleTokenVesting");
  const vesting = await Vesting.deploy(vestingFee, feeRecipient);
  await vesting.waitForDeployment();
  const vestingAddress = await vesting.getAddress();
  console.log("  MoonsaleTokenVesting:", vestingAddress);

  const vestingTx = vesting.deploymentTransaction();
  if (vestingTx) await vestingTx.wait(5);

  // ── Verify ────────────────────────────────────────────────────────────────────
  console.log("\nVerifying MoonsaleTokenLock...");
  try {
    await run("verify:verify", {
      address: lockAddress,
      constructorArguments: [lockFee, feeRecipient],
    });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  console.log("\nVerifying MoonsaleTokenVesting...");
  try {
    await run("verify:verify", {
      address: vestingAddress,
      constructorArguments: [vestingFee, feeRecipient],
    });
    console.log("  Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) console.log("  Already verified.");
    else console.warn("  Verification failed:", err.message);
  }

  const suffix = chainName === "bscTestnet" ? "BSCTESTNET" : chainName.toUpperCase();
  console.log(`\n✓ Add to your .env.local:`);
  console.log(`  NEXT_PUBLIC_TOKEN_LOCK_ADDRESS_${suffix}=${lockAddress}`);
  console.log(`  NEXT_PUBLIC_TOKEN_VESTING_ADDRESS_${suffix}=${vestingAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
