import {
  time,
  loadFixture,
} from "@nomicfoundation/hardhat-toolbox/network-helpers";
import { anyValue } from "@nomicfoundation/hardhat-chai-matchers/withArgs";
import { expect } from "chai";
import { ethers } from "hardhat";

describe("Stabilizer", function () {
  async function deployContract() {
    const pythContract = "0x5744Cbf430D99456a0A8771208b674F27f8EF0Fb"
    const pythPriceId = "0x5c6c0d2386e3352356c3ab84434fafb5ea067ac2678a38a338c4a69ddc4bdb0c"

    const [owner, otherAccount] = await ethers.getSigners();

    const Lock = await ethers.getContractFactory("Stabilizer");
    const contract = await Lock.deploy([pythContract, pythPriceId], { value: 0 });

    return { contract, owner, otherAccount };
  }
});
