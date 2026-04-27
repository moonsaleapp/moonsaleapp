import { ethers, network, run } from "hardhat";

async function main() {
  const chainName = network.name;
  console.log(`\nDeploying MoonsaleTokenFactory to ${chainName}...`);

  const [deployer] = await ethers.getSigners();
  console.log("Deployer:", deployer.address);
  console.log(
    "Balance:",
    ethers.formatEther(await ethers.provider.getBalance(deployer.address)),
    "BNB"
  );

  // 0.01 BNB creation fee on testnet, 0.05 BNB on mainnet
  const TESTNETS = ["bscTestnet", "sepolia", "baseSepolia", "mumbai", "arbitrumSepolia"];
  const isTestnet = TESTNETS.includes(chainName);
  const creationFee = ethers.parseEther(isTestnet ? "0.01" : "0.05");

  const Factory = await ethers.getContractFactory("MoonsaleTokenFactory");
  const factory = await Factory.deploy(creationFee, deployer.address);

  await factory.waitForDeployment();
  const factoryAddress = await factory.getAddress();

  console.log(`\nMoonsaleTokenFactory deployed to: ${factoryAddress}`);
  console.log(`Creation fee: ${ethers.formatEther(creationFee)} BNB`);
  console.log(`Fee recipient: ${deployer.address}`);

  // Wait for confirmations before verifying
  console.log("\nWaiting for block confirmations...");
  const deployTx = factory.deploymentTransaction();
  if (deployTx) await deployTx.wait(5);

  console.log("\nVerifying on BscScan...");
  try {
    await run("verify:verify", {
      address: factoryAddress,
      constructorArguments: [creationFee, deployer.address],
    });
    console.log("Verified!");
  } catch (err: any) {
    if (err.message?.includes("Already Verified")) {
      console.log("Already verified.");
    } else {
      console.warn("Verification failed:", err.message);
    }
  }

  const envKey = `NEXT_PUBLIC_TOKEN_FACTORY_ADDRESS_${chainName.toUpperCase()}`;
  console.log(`\n✓ Add to your .env.local:`);
  console.log(`  ${envKey}=${factoryAddress}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
