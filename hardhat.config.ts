import { HardhatUserConfig } from "hardhat/config";
import "@nomicfoundation/hardhat-toolbox";

const accounts = [
  { privateKey: "0xfd01f0afa367ece5fde4a6eb3c30b7986b8f8e565aee3b1705dfcfed583a3c00", publicKey: "0x8fddd21817486b5a7d38d47bc545c25cad7953ef" },
  { privateKey: "0xfd01f0afa367ece5fde4a6eb3c30b7986b8f8e565aee3b1705dfcfed583a3c01", publicKey: "0x3652798a07918c0ea0573d1d59b7cec1acb834bf" },
  { privateKey: "0xfd01f0afa367ece5fde4a6eb3c30b7986b8f8e565aee3b1705dfcfed583a3c02", publicKey: "0xb40c4c2567c5ec839fa214bb4a6fc013057c93b2" }
]

const config: HardhatUserConfig = {
  defaultNetwork: "fantomTestnet",
  solidity: {
    version: "0.8.20",
    settings: {
      viaIR: true,
      optimizer: {
       enabled: true,
       runs: 200,
       },
      },
     },
  networks: {
    fantomTestnet: {
      url: "https://rpc.testnet.fantom.network",
      accounts: accounts.map(account => account.privateKey),
    }
  }
};

export default config;
