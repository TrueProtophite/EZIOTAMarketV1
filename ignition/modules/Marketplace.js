const { buildModule } = require("@nomicfoundation/hardhat-ignition/modules");

module.exports = buildModule("MarketplaceModule", (m) => {
  const admin = m.getParameter("_adminAddress", "0x1FCAC2Ed5ceb3E54F7239E9e5ACCB1C9Ccc062C1");
  const treasuryAddress = m.getParameter("_treasuryAddress", "0x1FCAC2Ed5ceb3E54F7239E9e5ACCB1C9Ccc062C1");
  const fuelAddress = m.getParameter("_FUELAddress", "0x83b090759017EFC9cB4d9E45B813f5D5CbBFeb95");
  const fuelRate = m.getParameter("_fuelRate", 6300000000000000);

  const market = m.contract("EZIOTAMarketV1", [admin, treasuryAddress, fuelAddress, fuelRate]);

  return { market };
});
