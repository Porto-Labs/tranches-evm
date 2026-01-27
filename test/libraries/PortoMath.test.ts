import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { PortoMathHarness } from '../../typechain-types';

const { parseEther } = ethers;

describe('PortoMath', function () {
    let harness: PortoMathHarness;

    async function deployFixture() {
        const HarnessFactory = await ethers.getContractFactory('PortoMathHarness');
        const harness = await HarnessFactory.deploy();
        await harness.waitForDeployment();
        return { harness };
    }

    beforeEach(async function () {
        const fixture = await loadFixture(deployFixture);
        harness = fixture.harness;
    });

    describe('mulDown', function () {
        it('Should multiply and round down', async function () {
            const a = parseEther('2');
            const b = parseEther('3');
            expect(await harness.mulDown(a, b)).to.equal(parseEther('6'));
        });

        it('Should handle rounding down', async function () {
            const a = 1n;
            const b = parseEther('0.5');
            expect(await harness.mulDown(a, b)).to.equal(0n);
        });

        it('Should return zero when a is zero', async function () {
            expect(await harness.mulDown(0n, parseEther('1'))).to.equal(0n);
        });
    });

    describe('mulUp', function () {
        it('Should multiply and round up', async function () {
            const a = parseEther('2');
            const b = parseEther('3');
            expect(await harness.mulUp(a, b)).to.equal(parseEther('6'));
        });

        it('Should round up on fractional result', async function () {
            const a = parseEther('1');
            const b = 1n;
            expect(await harness.mulUp(a, b)).to.equal(1n);
        });

        it('Should return zero when product is zero', async function () {
            expect(await harness.mulUp(0n, parseEther('1'))).to.equal(0n);
        });
    });

    describe('divDown', function () {
        it('Should divide and round down', async function () {
            const a = parseEther('6');
            const b = parseEther('2');
            expect(await harness.divDown(a, b)).to.equal(parseEther('3'));
        });

        it('Should handle rounding down', async function () {
            const a = parseEther('1');
            const b = parseEther('3');
            const result = await harness.divDown(a, b);
            expect(result).to.be.lt(parseEther('0.333333333333333334'));
        });

        it('Should return zero when a is zero', async function () {
            expect(await harness.divDown(0n, parseEther('1'))).to.equal(0n);
        });

        context('Revert reasons', function () {
            it('Reverts when dividing by zero', async function () {
                await expect(harness.divDown(parseEther('1'), 0n)).to.be.revertedWithCustomError(
                    harness,
                    'DivisionByZero'
                );
            });
        });
    });

    describe('divUp', function () {
        it('Should divide and round up', async function () {
            const a = parseEther('6');
            const b = parseEther('2');
            expect(await harness.divUp(a, b)).to.equal(parseEther('3'));
        });

        it('Should round up on fractional result', async function () {
            const a = parseEther('1');
            const b = parseEther('3');
            const result = await harness.divUp(a, b);
            expect(result).to.be.gt(parseEther('0.333333333333333333'));
        });

        it('Should return zero when a is zero', async function () {
            expect(await harness.divUp(0n, parseEther('1'))).to.equal(0n);
        });

        context('Revert reasons', function () {
            it('Reverts when dividing by zero', async function () {
                await expect(harness.divUp(parseEther('1'), 0n)).to.be.revertedWithCustomError(
                    harness,
                    'DivisionByZero'
                );
            });

            it('Reverts when dividing zero by zero', async function () {
                await expect(harness.divUp(0n, 0n)).to.be.revertedWithCustomError(harness, 'DivisionByZero');
            });
        });
    });

    describe('min', function () {
        it('Should return smaller value', async function () {
            expect(await harness.min(parseEther('5'), parseEther('10'))).to.equal(parseEther('5'));
            expect(await harness.min(parseEther('10'), parseEther('5'))).to.equal(parseEther('5'));
        });

        it('Should handle equal values', async function () {
            expect(await harness.min(parseEther('5'), parseEther('5'))).to.equal(parseEther('5'));
        });
    });
});
