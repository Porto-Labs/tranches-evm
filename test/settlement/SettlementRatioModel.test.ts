import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { SettlementRatioModelHarness } from '../../typechain-types';

const { parseEther } = ethers;

describe('SettlementRatioModel', function () {
    let harness: SettlementRatioModelHarness;

    const ONE = parseEther('1');

    // Helper to create default params
    const defaultParams = () => ({
        uaQuantity: parseEther('100'),
        initialPrice: parseEther('1'),
        maturityPrice: parseEther('1'),
        seniorRatio: parseEther('0.7'),
        seniorFloor: parseEther('0.0033'),
        seniorTarget: parseEther('0.005'),
    });

    // Tolerance for comparisons (0.1% = 0.001)
    const TOLERANCE = parseEther('0.001');

    const abs = (n: bigint) => (n < 0n ? -n : n);

    const expectApproxEqual = (actual: bigint, expected: bigint) => {
        const diff = abs(actual - expected);
        const isClose = diff <= TOLERANCE;
        expect(isClose, `Expected ${ethers.formatEther(actual)} to be close to ${ethers.formatEther(expected)}`).to.be
            .true;
    };

    async function deployHarnessFixture() {
        const factory = await ethers.getContractFactory('SettlementRatioModelHarness');
        const harness = await factory.deploy();
        await harness.waitForDeployment();
        return { harness };
    }

    beforeEach(async function () {
        const fixture = await loadFixture(deployHarnessFixture);
        harness = fixture.harness;
    });

    describe('calculatePrincipals', function () {
        it('Should calculate principals correctly with standard ratio', async function () {
            const [pSr, pJr] = await harness.calculatePrincipals(parseEther('100'), parseEther('1'), parseEther('0.7'));

            expect(pSr).to.equal(parseEther('70'));
            expect(pJr).to.equal(parseEther('30'));
        });

        it('Should handle different prices', async function () {
            const [pSr, pJr] = await harness.calculatePrincipals(
                parseEther('100'),
                parseEther('1.5'),
                parseEther('0.7')
            );

            expect(pSr).to.equal(parseEther('105'));
            expect(pJr).to.equal(parseEther('45'));
        });
    });

    describe('calculateThresholds', function () {
        it('Should calculate floor and target thresholds correctly', async function () {
            const [vFloor, vTarget] = await harness.calculateThresholds(
                parseEther('70'),
                parseEther('0.0033'),
                parseEther('0.005')
            );

            expectApproxEqual(vFloor, parseEther('70.231'));
            expectApproxEqual(vTarget, parseEther('70.35'));
        });
    });

    describe('calculatePayouts', function () {
        const pJr = parseEther('30');
        const vFloor = parseEther('70.231');
        const vTarget = parseEther('70.35');

        it('Should return target payout when in Surplus condition', async function () {
            const vTotal = parseEther('101');
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(vTarget);
            expectApproxEqual(result.juniorPayout, parseEther('30.65'));
        });

        it('Should compress senior yield when in Compression condition', async function () {
            const vTotal = parseEther('100.30');
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expectApproxEqual(result.seniorPayout, parseEther('70.30'));
            expect(result.juniorPayout).to.equal(pJr);
        });

        it('Should erode junior when in Erosion condition', async function () {
            const vTotal = parseEther('100');
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(vFloor);
            expectApproxEqual(result.juniorPayout, parseEther('29.769'));
        });

        it('Should wipe out junior when total value below floor', async function () {
            const vTotal = parseEther('60');
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(vTotal);
            expect(result.juniorPayout).to.equal(0n);
        });

        it('Should handle total loss scenario', async function () {
            const vTotal = parseEther('0');
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(0n);
            expect(result.juniorPayout).to.equal(0n);
        });

        it('Should handle exact boundary at target + junior', async function () {
            const vTotal = vTarget + pJr;
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(vTarget);
            expect(result.juniorPayout).to.equal(pJr);
        });

        it('Should handle exact boundary at floor + junior', async function () {
            const vTotal = vFloor + pJr;
            const result = await harness.calculatePayouts(vTotal, pJr, vFloor, vTarget);

            expect(result.seniorPayout).to.equal(vFloor);
            expect(result.juniorPayout).to.equal(pJr);
        });
    });

    describe('calculateRates', function () {
        it('Should return 1:1 rates when price unchanged', async function () {
            const [srRate, jrRate] = await harness.calculateRates(
                parseEther('70'),
                parseEther('30'),
                parseEther('1'),
                parseEther('100'),
                parseEther('0.7')
            );

            expect(srRate).to.equal(ONE);
            expect(jrRate).to.equal(ONE);
        });

        it('Should calculate correct rates when price increases', async function () {
            const [srRate, jrRate] = await harness.calculateRates(
                parseEther('70.35'),
                parseEther('30.65'),
                parseEther('1.01'),
                parseEther('100'),
                parseEther('0.7')
            );

            expectApproxEqual(srRate, parseEther('0.995'));
            expectApproxEqual(jrRate, parseEther('1.011'));
        });
    });

    describe('calculateSettlement', function () {
        it('Should calculate Surplus scenario correctly', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1.01'),
            };

            const result = await harness.calculateSettlement(params);

            expectApproxEqual(result.srRateUA, parseEther('0.995'));
            expectApproxEqual(result.jrRateUA, parseEther('1.011'));
        });

        it('Should calculate Compression scenario correctly', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1.003'),
            };

            const result = await harness.calculateSettlement(params);

            expectApproxEqual(result.srRateUA, parseEther('1.001'));
            expectApproxEqual(result.jrRateUA, parseEther('0.997'));
        });

        it('Should calculate Erosion scenario correctly', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1'),
            };

            const result = await harness.calculateSettlement(params);

            expectApproxEqual(result.srRateUA, parseEther('1.003'));
            expectApproxEqual(result.jrRateUA, parseEther('0.992'));
        });

        it('Should handle junior wipeout scenario', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('0.70'),
            };

            const result = await harness.calculateSettlement(params);

            expect(result.jrRateUA).to.equal(0n);
        });

        it('Should handle total loss scenario', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('0.50'),
            };

            const result = await harness.calculateSettlement(params);

            expect(result.jrRateUA).to.equal(0n);
            expectApproxEqual(result.srRateUA, parseEther('1.428'));
        });

        it('Should satisfy redemption invariant: distributed == available', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1.01'),
            };

            const result = await harness.calculateSettlement(params);

            const srSupply = (params.uaQuantity * params.seniorRatio) / ONE;
            const jrSupply = params.uaQuantity - srSupply;

            const srDistributed = (srSupply * result.srRateUA) / ONE;
            const jrDistributed = (jrSupply * result.jrRateUA) / ONE;
            const totalDistributed = srDistributed + jrDistributed;

            expect(totalDistributed).to.equal(params.uaQuantity);
        });

        describe('Revert reasons', function () {
            it('Reverts when maturity price is zero', async function () {
                const params = {
                    ...defaultParams(),
                    maturityPrice: parseEther('0'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementZeroPrice'
                );
            });

            it('Reverts when initial price is zero', async function () {
                const params = {
                    ...defaultParams(),
                    initialPrice: parseEther('0'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementZeroPrice'
                );
            });

            it('Reverts when UA quantity is zero', async function () {
                const params = {
                    ...defaultParams(),
                    uaQuantity: parseEther('0'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementZeroQuantity'
                );
            });

            it('Reverts when senior ratio is zero', async function () {
                const params = {
                    ...defaultParams(),
                    seniorRatio: parseEther('0'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementInvalidRatio'
                );
            });

            it('Reverts when senior ratio >= 1', async function () {
                const params = {
                    ...defaultParams(),
                    seniorRatio: parseEther('1'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementInvalidRatio'
                );
            });

            it('Reverts when floor > target', async function () {
                const params = {
                    ...defaultParams(),
                    seniorFloor: parseEther('0.01'),
                    seniorTarget: parseEther('0.005'),
                };

                await expect(harness.calculateSettlement(params)).to.be.revertedWithCustomError(
                    harness,
                    'SettlementInvalidYieldRange'
                );
            });
        });
    });
});
