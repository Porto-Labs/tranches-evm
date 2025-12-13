import { expect } from 'chai';
import hre from 'hardhat';
import { PortoTranches } from '../typechain-types';

describe('PortoTranches', function () {
    let portoTranches: PortoTranches;

    beforeEach(async function () {
        const PortoTranchesFactory = await hre.ethers.getContractFactory('PortoTranches');
        portoTranches = (await PortoTranchesFactory.deploy()) as PortoTranches;
        await portoTranches.deployed();
    });

    it('should deploy successfully', async function () {
        expect(portoTranches.address).to.properAddress;
    });

    it('should return correct version', async function () {
        const version = await portoTranches.getVersion();
        expect(version).to.equal('0.1.0');
    });

    it('should emit Initialized event on deployment', async function () {
        const PortoTranchesFactory = await hre.ethers.getContractFactory('PortoTranches');
        const [deployer] = await hre.ethers.getSigners();
        const deployTx = await PortoTranchesFactory.deploy();
        await expect(deployTx.deployTransaction).to.emit(deployTx, 'Initialized').withArgs(deployer.address);
    });
});
