import { ethers, network, run } from "hardhat";

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying MoonsaleTokenManager to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "BNB"
  );

  const TESTNETS    = ["bscTestnet", "sepolia", "baseSepolia", "mumbai", "arbitrumSepolia"];
  const isTestnet   = TESTNETS.includes(chainName);
  const managementFee = ethers.parseEther(isTestnet ? "0.005" : "0.006");

  const Manager = await ethers.getContractFactory("MoonsaleTokenManager");
  const manager = await Manager.deploy(managementFee, deployer.address);

  await manager.waitForDeployment();
  const managerAddress = await manager.getAddress();

  console.log(`\nMoonsaleTokenManager deployed to: ${managerAddress}`);
  console.log(`Management fee: ${ethers.formatEther(managementFee)} BNB`);
  console.log(`Fee recipient: ${deployer.address}`);

  console.log("\nWaiting for block confirmations...");
  const deployTx = manager.deploymentTransaction();
  if (deployTx) await deployTx.wait(5);

  console.log("\nVerifying on BscScan...");
  try {
    await run("verify:verify", {
      address: managerAddress,
      constructorArguments: [managementFee, deployer.address],
    });
    console.log("Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) {
      console.log("Already verified.");
    } else {
      console.warn("Verification failed:", err.message);
    }
  }

  const envKey = `NEXT_PUBLIC_TOKEN_MANAGER_ADDRESS_${chainName.toUpperCase()}`;
  console.log(`\n✓ Add to your .env.local:`);
  console.log(`  ${envKey}=${managerAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
