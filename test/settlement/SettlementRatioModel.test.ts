import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture } from '@nomicfoundation/hardhat-network-helpers';
import { SettlementRatioModelHarness } from '../../typechain-types';

const { parseEther } = ethers;

describe('SettlementRatioModel', function () {
    let harness: SettlementRatioModelHarness;

    // Local math helpers (minimal, just what's needed)
    const ONE = parseEther('1');
    const mulDown = (a: bigint, b: bigint): bigint => (a * b) / ONE;

    // Default test params
    const defaultParams = () => ({
        uaQuantity: parseEther('100'),
        initialPrice: parseEther('1'),
        maturityPrice: parseEther('1'),
        seniorRatio: parseEther('0.7'),
        seniorFloor: parseEther('0.0033'),
        seniorTarget: parseEther('0.005'),
    });

    /**
     * Assert no over-distribution invariant.
     * This is the critical safety property: distributed <= available.
     */
    function assertNoOverDistribution(
        uaQuantity: bigint,
        seniorRatio: bigint,
        srRateUA: bigint,
        jrRateUA: bigint
    ): void {
        const srSupply = mulDown(uaQuantity, seniorRatio);
        const jrSupply = uaQuantity - srSupply;

        const srDistributed = mulDown(srSupply, srRateUA);
        const jrDistributed = mulDown(jrSupply, jrRateUA);
        const totalDistributed = srDistributed + jrDistributed;

        expect(totalDistributed).to.be.lte(
            uaQuantity,
            `Over-distribution: ${ethers.formatEther(totalDistributed)} > ${ethers.formatEther(uaQuantity)}`
        );
    }

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
            const [srPrincipal, jrPrincipal] = await harness.calculatePrincipals(
                parseEther('100'),
                parseEther('1'),
                parseEther('0.7')
            );

            // totalValue = 100 * 1 = 100
            // srPrincipal = 100 * 0.7 = 70
            // jrPrincipal = 100 - 70 = 30
            expect(srPrincipal).to.equal(parseEther('70'));
            expect(jrPrincipal).to.equal(parseEther('30'));
        });

        it('Should handle different prices', async function () {
            const [srPrincipal, jrPrincipal] = await harness.calculatePrincipals(
                parseEther('100'),
                parseEther('1.5'),
                parseEther('0.7')
            );

            // totalValue = 100 * 1.5 = 150
            // srPrincipal = 150 * 0.7 = 105
            // jrPrincipal = 150 - 105 = 45
            expect(srPrincipal).to.equal(parseEther('105'));
            expect(jrPrincipal).to.equal(parseEther('45'));
        });

        it('Should handle 50/50 ratio', async function () {
            const [srPrincipal, jrPrincipal] = await harness.calculatePrincipals(
                parseEther('100'),
                parseEther('1'),
                parseEther('0.5')
            );

            expect(srPrincipal).to.equal(parseEther('50'));
            expect(jrPrincipal).to.equal(parseEther('50'));
        });
    });

    describe('calculateThresholds', function () {
        it('Should calculate floor and target thresholds correctly', async function () {
            const srPrincipal = parseEther('70');
            const seniorFloorYield = parseEther('0.0033'); // 0.33%
            const seniorTargetYield = parseEther('0.005'); // 0.5%

            const [srFloorUsd, srTargetUsd] = await harness.calculateThresholds(
                srPrincipal,
                seniorFloorYield,
                seniorTargetYield
            );

            // srFloorUsd = 70 * (1 + 0.0033) = 70 * 1.0033 = 70.231
            // srTargetUsd = 70 * (1 + 0.005) = 70 * 1.005 = 70.35
            expect(srFloorUsd).to.equal(parseEther('70.231'));
            expect(srTargetUsd).to.equal(parseEther('70.35'));
        });

        it('Should handle zero yield thresholds', async function () {
            const srPrincipal = parseEther('100');
            const seniorFloorYield = parseEther('0');
            const seniorTargetYield = parseEther('0');

            const [srFloorUsd, srTargetUsd] = await harness.calculateThresholds(
                srPrincipal,
                seniorFloorYield,
                seniorTargetYield
            );

            // srFloorUsd = 100 * 1.0 = 100
            // srTargetUsd = 100 * 1.0 = 100
            expect(srFloorUsd).to.equal(parseEther('100'));
            expect(srTargetUsd).to.equal(parseEther('100'));
        });
    });

    describe('calculatePayouts', function () {
        // Fixed thresholds for this test suite
        // srPrincipal = 70, floor = 0.33%, target = 0.5%
        const jrPrincipalUsd = parseEther('30');
        const srFloorUsd = parseEther('70.231'); // 70 * 1.0033
        const srTargetUsd = parseEther('70.35'); // 70 * 1.005

        it('Should return target payout when in Surplus condition', async function () {
            // Surplus: totalValue >= target + jrPrincipal = 70.35 + 30 = 100.35
            const totalValueUsd = parseEther('101');
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(srTargetUsd);
            expect(result.juniorPayout).to.equal(totalValueUsd - srTargetUsd);
        });

        it('Should compress senior yield when in Compression condition', async function () {
            // Compression: floor + jrPrincipal <= totalValue < target + jrPrincipal
            // [100.231, 100.35)
            const totalValueUsd = parseEther('100.3');
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(totalValueUsd - jrPrincipalUsd);
            expect(result.juniorPayout).to.equal(jrPrincipalUsd);
        });

        it('Should erode junior when in Erosion condition', async function () {
            // Erosion: totalValue < floor + jrPrincipal but >= floor
            // totalValue = 100 < 100.231, and 100 >= 70.231
            const totalValueUsd = parseEther('100');
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(srFloorUsd);
            expect(result.juniorPayout).to.equal(totalValueUsd - srFloorUsd);
        });

        it('Should wipe out junior when total value below floor', async function () {
            const totalValueUsd = parseEther('60');
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(totalValueUsd);
            expect(result.juniorPayout).to.equal(0n);
        });

        it('Should handle total loss scenario', async function () {
            const totalValueUsd = parseEther('0');
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(0n);
            expect(result.juniorPayout).to.equal(0n);
        });

        it('Should handle exact boundary at target + junior', async function () {
            const totalValueUsd = srTargetUsd + jrPrincipalUsd; // 100.35
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(srTargetUsd);
            expect(result.juniorPayout).to.equal(jrPrincipalUsd);
        });

        it('Should handle exact boundary at floor + junior', async function () {
            const totalValueUsd = srFloorUsd + jrPrincipalUsd; // 100.231
            const result = await harness.calculatePayouts(totalValueUsd, jrPrincipalUsd, srFloorUsd, srTargetUsd);

            expect(result.seniorPayout).to.equal(srFloorUsd);
            expect(result.juniorPayout).to.equal(jrPrincipalUsd);
        });
    });

    describe('calculateRates', function () {
        it('Should return 1:1 rates when price unchanged and payouts equal principals', async function () {
            const [srRate, jrRate] = await harness.calculateRates(
                parseEther('70'), // seniorPayout
                parseEther('30'), // juniorPayout
                parseEther('1'), // maturityPrice
                parseEther('100'), // uaQuantity
                parseEther('0.7') // seniorRatio
            );

            expect(srRate).to.equal(ONE);
            expect(jrRate).to.equal(ONE);
        });

        it('Should handle zero junior payout', async function () {
            const [srRate, jrRate] = await harness.calculateRates(
                parseEther('70'), // all goes to senior
                parseEther('0'), // junior wiped
                parseEther('1'),
                parseEther('100'),
                parseEther('0.7')
            );

            expect(srRate).to.equal(ONE);
            expect(jrRate).to.equal(0n);
        });
    });

    describe('calculateSettlement', function () {
        it('Should handle Surplus scenario (price up)', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1.01'), // +1%
            };

            const result = await harness.calculateSettlement(params);

            // Senior is capped at target yield (70.35 USD), converting to UA gives < 70 tokens
            // Junior absorbs the excess (30.65 USD > 30 USD principal), so jrRate > 1
            expect(result.srRateUA).to.be.lt(ONE);
            expect(result.jrRateUA).to.be.gt(ONE);
            assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        });

        it('Should handle Compression scenario', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1.003'), // +0.3%
            };

            const result = await harness.calculateSettlement(params);

            // Senior gets some yield, junior at principal
            expect(result.srRateUA).to.be.gt(ONE);
            assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        });

        it('Should handle Erosion scenario (price flat)', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('1'), // no change
            };

            const result = await harness.calculateSettlement(params);

            // With floor=0.33% and target=0.5%, flat price means erosion
            // Senior at floor, junior eroded
            assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        });

        it('Should handle junior wipeout scenario', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('0.70'), // -30%
            };

            const result = await harness.calculateSettlement(params);

            expect(result.jrRateUA).to.equal(0n);
            assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        });

        it('Should handle severe loss scenario', async function () {
            const params = {
                ...defaultParams(),
                maturityPrice: parseEther('0.50'), // -50%
            };

            const result = await harness.calculateSettlement(params);

            expect(result.jrRateUA).to.equal(0n);
            // When price goes DOWN, converting USD payout to UA gives MORE tokens
            // But the total UA available limits distribution (checked by invariant)
            assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
        });

        it('Should never over-distribute across various price scenarios', async function () {
            const prices = ['0.5', '0.7', '0.9', '1.0', '1.003', '1.005', '1.01', '1.1', '1.5'];

            for (const priceStr of prices) {
                const params = {
                    ...defaultParams(),
                    maturityPrice: parseEther(priceStr),
                };

                const result = await harness.calculateSettlement(params);
                assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
            }
        });

        it('Should never over-distribute across various ratios', async function () {
            const ratios = ['0.1', '0.3', '0.5', '0.7', '0.9', '0.99'];

            for (const ratioStr of ratios) {
                const params = {
                    ...defaultParams(),
                    seniorRatio: parseEther(ratioStr),
                    maturityPrice: parseEther('1.01'),
                };

                const result = await harness.calculateSettlement(params);
                assertNoOverDistribution(params.uaQuantity, params.seniorRatio, result.srRateUA, result.jrRateUA);
            }
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
