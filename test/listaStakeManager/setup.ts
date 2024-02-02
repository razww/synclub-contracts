import { expect } from "chai";
import { ethers, upgrades } from "hardhat";
import { loadFixture } from "ethereum-waffle";
import { accountFixture, deployFixture } from "../fixture";

describe("ListaStakeManager::setup", function() {
  const ADDRESS_ZERO = ethers.constants.AddressZero;

  before(async function() {
    const { deployer, addrs } = await loadFixture(accountFixture);
    this.addrs = addrs;
    this.deployer = deployer;
  });

  it("Can't deploy with zero contract", async function() {
    const { deployContract } = await loadFixture(deployFixture);
    const listaStakeManager = await deployContract("ListaStakeManager");

    await expect(
      upgrades.deployProxy(await ethers.getContractFactory("ListaStakeManager"), [
        ADDRESS_ZERO,
        ADDRESS_ZERO,
        ADDRESS_ZERO,
        ADDRESS_ZERO,
        ADDRESS_ZERO,
        1_000,
        ADDRESS_ZERO,
        ADDRESS_ZERO,
      ])
    ).to.be.revertedWith("zero address provided");

    await expect(
      upgrades.deployProxy(await ethers.getContractFactory("ListaStakeManager"), [
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        this.addrs[4].address,
        1_000_000_000_00,
        this.addrs[5].address,
        this.addrs[6].address,
      ])
    ).to.be.revertedWith("_synFee must not exceed (100%)");
  });

  it("Should be able to setup contract with properly configurations", async function() {
    const listaStakeManager = await upgrades.deployProxy(
      await ethers.getContractFactory("ListaStakeManager"),
      [
        this.addrs[0].address,
        this.addrs[1].address,
        this.addrs[2].address,
        this.addrs[3].address,
        this.addrs[4].address,
        1_000,
        this.addrs[5].address,
        this.addrs[6].address,
      ]
    );
    await listaStakeManager.deployed();

    expect(await listaStakeManager.slisbnb()).to.eq(this.addrs[0].address);
    expect(await listaStakeManager.lisbnb()).to.eq(this.addrs[1].address);
    expect(await listaStakeManager.admin()).to.eq(this.addrs[2].address);
    expect(await listaStakeManager.bot()).to.eq(this.addrs[3].address);
    expect(await listaStakeManager.sn()).to.eq(this.addrs[4].address);
    expect(await listaStakeManager.synFee()).to.eq(1_000);
    expect(await listaStakeManager.synthLp()).to.eq(this.addrs[5].address);
    expect(await listaStakeManager.snLp()).to.eq(this.addrs[6].address);
  });
});
