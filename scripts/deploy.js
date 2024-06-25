const hre = require("hardhat");

async function main() {
	const marketplace = await hre.ethers.deployContract("EZIOTAMarketV1", ["0x20c6e6bb0f14ff4714e9af66fd8c67c03f64e00d", "0x20c6e6bb0f14ff4714e9af66fd8c67c03f64e00d", "0xB2E0DfC4820cc55829C71529598530E177968613", "0x83b090759017EFC9cB4d9E45B813f5D5CbBFeb95", 10000000000, 2000000000000, 6300000000000000]);

	await marketplace.waitForDeployment();

	console.log("Contract address: " + await marketplace.getAddress());
}

main().catch((error) => {
	console.error(error);
	process.exitCode = 1;
});



