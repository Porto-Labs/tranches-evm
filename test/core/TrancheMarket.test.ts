import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { TrancheMarket, ERC20Mock, MockChainlinkAggregator } from '../../typechain-types';
import { TIME } from '../utils';

const { parseEther, ZeroAddress } = ethers;

const mulDown = (a: bigint, b: bigint): bigint => (a * b) / parseEther('1');

describe('TrancheMarket', function () {
    let market: TrancheMarket;
    let ua: ERC20Mock;
    let oracle: MockChainlinkAggregator;
    let admin: SignerWithAddress;
    let user: SignerWithAddress;

    const ONE = parseEther('1');

    // Default market params
    const defaultMarketParams = async (
        uaAddress: string,
        oracleAddress: string,
        adminAddress: string,
        expiryOffset: number = TIME.MONTH
    ) => ({
        ua: uaAddress,
        expiry: (await time.latest()) + expiryOffset,
        seniorRatio: parseEther('0.7'),
        admin: adminAddress,
        priceFeed: oracleAddress,
        seniorFloor: parseEther('0.0033'), // 0.33%
        seniorTarget: parseEther('0.005'), // 0.5%
        liquidationEnabled: false,
        liquidationBuffer: 0n,
        liquidationReward: 0n,
    });

    async function deployFixture() {
        const [admin, user] = await ethers.getSigners();

        // Deploy mock UA token
        const ERC20MockFactory = await ethers.getContractFactory('ERC20Mock');
        const ua = await ERC20MockFactory.deploy('Underlying Asset', 'UA');
        await ua.waitForDeployment();

        // Deploy mock oracle with 8 decimals (standard Chainlink)
        const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
        const oracle = await MockOracleFactory.deploy(8, 'UA / USD');
        await oracle.waitForDeployment();

        // Set initial price: $1.00 = 1e8 (8 decimals)
        await oracle.setRoundData(100000000n, await time.latest());

        // Deploy market
        const MarketFactory = await ethers.getContractFactory('TrancheMarket');
        const params = await defaultMarketParams(await ua.getAddress(), await oracle.getAddress(), admin.address);
        const market = await MarketFactory.deploy(params);
        await market.waitForDeployment();

        // Mint UA to user and approve market
        await ua.mint(user.address, parseEther('1000'));
        await ua.connect(user).approve(await market.getAddress(), parseEther('1000'));

        return { market, ua, oracle, admin, user };
    }

    beforeEach(async function () {
        const fixture = await loadFixture(deployFixture);
        market = fixture.market;
        ua = fixture.ua;
        oracle = fixture.oracle;
        admin = fixture.admin;
        user = fixture.user;
    });

    describe('Constructor', function () {
        it('Should set oracle immutables correctly', async function () {
            expect(await market.priceFeed()).to.equal(await oracle.getAddress());
            expect(await market.initialPrice()).to.equal(parseEther('1'));
            expect(await market.seniorFloor()).to.equal(parseEther('0.0033'));
            expect(await market.seniorTarget()).to.equal(parseEther('0.005'));
        });

        it('Should calculate juniorRatio from seniorRatio', async function () {
            expect(await market.seniorRatio()).to.equal(parseEther('0.7'));
            expect(await market.juniorRatio()).to.equal(parseEther('0.3'));
        });

        it('Should derive token names and symbols from UA token', async function () {
            const srTokenAddr = await market.srToken();
            const jrTokenAddr = await market.jrToken();
            const srToken = await ethers.getContractAt('TrancheToken', srTokenAddr);
            const jrToken = await ethers.getContractAt('TrancheToken', jrTokenAddr);

            expect(await srToken.symbol()).to.equal('srUA');
            expect(await jrToken.symbol()).to.equal('jrUA');
            expect(await srToken.name()).to.equal('Porto srUA');
            expect(await jrToken.name()).to.equal('Porto jrUA');
        });

        context('Revert reasons', function () {
            it('Reverts when price feed is zero address', async function () {
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(await ua.getAddress(), ZeroAddress, admin.address);

                await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(market, 'ZeroAddress');
            });

            it('Reverts when oracle returns zero price', async function () {
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
                const zeroOracle = await MockOracleFactory.deploy(8, 'UA / USD');
                await zeroOracle.setRoundData(0, await time.latest());

                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await zeroOracle.getAddress(),
                    admin.address
                );

                await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(market, 'OracleInvalidPrice');
            });

            it('Reverts when floor exceeds target', async function () {
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                params.seniorFloor = parseEther('0.01');
                params.seniorTarget = parseEther('0.005');

                await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(
                    market,
                    'SettlementInvalidYieldRange'
                );
            });

            it('Reverts when seniorRatio is zero', async function () {
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                params.seniorRatio = 0n;

                await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(
                    market,
                    'TrancheInvalidWeights'
                );
            });

            it('Reverts when seniorRatio is 100%', async function () {
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                params.seniorRatio = parseEther('1');

                await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(
                    market,
                    'TrancheInvalidWeights'
                );
            });
        });
    });

    context('when fetching oracle prices', function () {
        it('Should scale 8 decimal price to 18 decimals correctly', async function () {
            // Tranche UA to have tokens in the market
            await market.connect(user).tranche(parseEther('100'), user.address);

            // Move past expiry
            await time.increase(TIME.MONTH + 1);

            // Set oracle to $1.50 (150000000 in 8 decimals) - after time increase to avoid staleness
            await oracle.setRoundData(150000000n, await time.latest());

            // Preview should return price in 18 decimal precision
            const [, , oraclePrice] = await market.previewSettlement();
            expect(oraclePrice).to.equal(parseEther('1.5'));
        });

        it('Should handle 18 decimal oracle', async function () {
            // Deploy new oracle with 18 decimals
            const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
            const oracle18 = await MockOracleFactory.deploy(18, 'UA / USD');
            await oracle18.setRoundData(parseEther('1.25'), await time.latest()); // $1.25 in 18 decimals

            // Deploy new market with 18 decimal oracle
            const MarketFactory = await ethers.getContractFactory('TrancheMarket');
            const params = await defaultMarketParams(await ua.getAddress(), await oracle18.getAddress(), admin.address);
            const market18 = await MarketFactory.deploy(params);

            await ua.connect(user).approve(await market18.getAddress(), parseEther('100'));
            await market18.connect(user).tranche(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);

            // Refresh oracle price after time increase
            await oracle18.setRoundData(parseEther('1.25'), await time.latest());

            const [, , oraclePrice] = await market18.previewSettlement();
            expect(oraclePrice).to.equal(parseEther('1.25'));
        });

        it('Should handle 6 decimal oracle', async function () {
            // Deploy new oracle with 6 decimals
            const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
            const oracle6 = await MockOracleFactory.deploy(6, 'UA / USD');
            await oracle6.setRoundData(2000000n, await time.latest()); // $2.00 in 6 decimals

            // Deploy new market with 6 decimal oracle
            const MarketFactory = await ethers.getContractFactory('TrancheMarket');
            const params = await defaultMarketParams(await ua.getAddress(), await oracle6.getAddress(), admin.address);
            const market6 = await MarketFactory.deploy(params);

            await ua.connect(user).approve(await market6.getAddress(), parseEther('100'));
            await market6.connect(user).tranche(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);

            // Refresh oracle price after time increase
            await oracle6.setRoundData(2000000n, await time.latest());

            const [, , oraclePrice] = await market6.previewSettlement();
            expect(oraclePrice).to.equal(parseEther('2'));
        });
    });

    describe('finalize', function () {
        beforeEach(async function () {
            // Tranche UA to have tokens in the market
            await market.connect(user).tranche(parseEther('100'), user.address);
            // Move past expiry
            await time.increase(TIME.MONTH + 1);
            // Refresh oracle price after time increase (set to $1.00)
            await oracle.setRoundData(100000000n, await time.latest());
        });

        it('Should finalize with valid reference price and deviation', async function () {
            // Oracle at $1.00, reference at $1.00, threshold 1%
            const referencePrice = parseEther('1');
            const deviationThreshold = parseEther('0.01');

            await expect(market.connect(admin).finalize(referencePrice, deviationThreshold)).to.emit(
                market,
                'Finalize'
            );

            expect(await market.finalized()).to.be.true;
            expect(await market.srRateUA()).to.be.gt(0n);
        });

        it('Should accept price within deviation threshold', async function () {
            // Set oracle to $1.05 (+5%)
            await oracle.setRoundData(105000000n, await time.latest());

            // Reference at $1.00, threshold 10% - should pass
            const referencePrice = parseEther('1');
            const deviationThreshold = parseEther('0.10');

            await market.connect(admin).finalize(referencePrice, deviationThreshold);
            expect(await market.finalized()).to.be.true;
        });

        it('Should handle negative deviation', async function () {
            // Set oracle to $0.95 (-5%)
            await oracle.setRoundData(95000000n, await time.latest());

            // Reference at $1.00, threshold 10% - should pass
            const referencePrice = parseEther('1');
            const deviationThreshold = parseEther('0.10');

            await market.connect(admin).finalize(referencePrice, deviationThreshold);
            expect(await market.finalized()).to.be.true;
        });

        it('Should accept price at 24 hour threshold boundary', async function () {
            // Set price exactly 24 hours old (should still be valid)
            const currentTime = await time.latest();
            await oracle.setRoundData(100000000n, currentTime - (24 * 60 * 60 - 10));

            await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));
            expect(await market.finalized()).to.be.true;
        });

        it('Should emit Finalize event with correct values', async function () {
            await oracle.setRoundData(101000000n, await time.latest()); // $1.01

            const tx = await market.connect(admin).finalize(parseEther('1'), parseEther('0.05'));
            const receipt = await tx.wait();

            // Check event args
            const event = receipt?.logs.find((log: any) => log.fragment?.name === 'Finalize') as any;

            expect(event).to.not.be.undefined;
            expect(event.args[0]).to.equal(parseEther('1.01')); // oraclePrice
            expect(event.args[1]).to.equal(parseEther('1')); // referencePrice
            expect(event.args[2]).to.be.gt(0n); // srRateUA
        });

        context('Revert reasons', function () {
            it('Reverts when oracle price deviates too much', async function () {
                // Set oracle to $1.10 (+10%)
                await oracle.setRoundData(110000000n, await time.latest());

                // Reference at $1.00, threshold 5% - should fail
                const referencePrice = parseEther('1');
                const deviationThreshold = parseEther('0.05');

                await expect(
                    market.connect(admin).finalize(referencePrice, deviationThreshold)
                ).to.be.revertedWithCustomError(market, 'OraclePriceDeviationExceeded');
            });

            it('Reverts when deviation threshold exceeds 100%', async function () {
                const referencePrice = parseEther('1');
                const deviationThreshold = parseEther('1.01'); // 101%

                await expect(
                    market.connect(admin).finalize(referencePrice, deviationThreshold)
                ).to.be.revertedWithCustomError(market, 'OracleInvalidDeviationThreshold');
            });

            it('Reverts when reference price is zero', async function () {
                const referencePrice = 0n;
                const deviationThreshold = parseEther('0.01');

                await expect(
                    market.connect(admin).finalize(referencePrice, deviationThreshold)
                ).to.be.revertedWithCustomError(market, 'SettlementZeroPrice');
            });

            it('Reverts when oracle returns zero price', async function () {
                await oracle.setRoundData(0, await time.latest());

                await expect(
                    market.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(market, 'OracleInvalidPrice');
            });

            it('Reverts when oracle returns negative price', async function () {
                await oracle.setRoundData(-100000000, await time.latest());

                await expect(
                    market.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(market, 'OracleInvalidPrice');
            });

            it('Reverts when oracle price is stale', async function () {
                // Set stale price (25 hours old)
                const currentTime = await time.latest();
                await oracle.setRoundData(100000000n, currentTime - 25 * 60 * 60);

                await expect(
                    market.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(market, 'OracleStalePrice');
            });

            it('Reverts when called before expiry', async function () {
                // Deploy fresh market
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                const freshMarket = await MarketFactory.deploy(params);

                await expect(
                    freshMarket.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(freshMarket, 'TrancheMarketNotExpired');
            });

            it('Reverts when already finalized', async function () {
                await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));

                await expect(
                    market.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(market, 'TrancheMarketAlreadyFinalized');
            });

            it('Reverts when called by non-admin', async function () {
                await expect(
                    market.connect(user).finalize(parseEther('1'), parseEther('0.01'))
                ).to.be.revertedWithCustomError(market, 'OnlyAdmin');
            });
        });
    });

    context('when calculating waterfall conditions', function () {
        beforeEach(async function () {
            await market.connect(user).tranche(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);
            // Oracle will be set in each test with the specific price
        });

        it('Should handle Surplus scenario (price up - senior capped)', async function () {
            // Set oracle to $1.01 (+1% gain)
            await oracle.setRoundData(101000000n, await time.latest());

            await market.connect(admin).finalize(parseEther('1.01'), parseEther('0.01'));

            const srRate = await market.srRateUA();
            const jrRate = await market.jrRateUA();

            // Senior should be capped (rate < 1 because capped in USD means less UA)
            expect(srRate).to.be.lt(ONE);
            // Junior should benefit from excess (rate > 1)
            expect(jrRate).to.be.gt(ONE);
        });

        it('Should handle Compression scenario (slight gain)', async function () {
            // Set oracle to $1.004 (between floor and target)
            await oracle.setRoundData(100400000n, await time.latest());

            await market.connect(admin).finalize(parseEther('1.004'), parseEther('0.01'));

            const srRate = await market.srRateUA();
            const jrRate = await market.jrRateUA();

            // Senior gets some yield
            // Junior at approximately principal
            expect(srRate).to.be.gt(0n);
            expect(jrRate).to.be.gt(0n);
        });

        it('Should handle Erosion scenario (price flat - junior eroded)', async function () {
            // Set oracle to $1.00 (no gain)
            await oracle.setRoundData(100000000n, await time.latest());

            await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));

            const srRate = await market.srRateUA();
            const jrRate = await market.jrRateUA();

            // Senior protected at floor
            expect(srRate).to.be.gt(0n);
            // Junior eroded but not wiped
            expect(jrRate).to.be.lt(ONE);
        });

        it('Should handle severe loss scenario (junior wiped)', async function () {
            // Set oracle to $0.70 (-30% loss)
            await oracle.setRoundData(70000000n, await time.latest());

            await market.connect(admin).finalize(parseEther('0.70'), parseEther('0.01'));

            const srRate = await market.srRateUA();
            const jrRate = await market.jrRateUA();

            // Junior should be wiped
            expect(jrRate).to.equal(0n);
            // Senior takes what's available
            expect(srRate).to.be.gt(0n);
        });
    });

    describe('previewSettlement', function () {
        beforeEach(async function () {
            await market.connect(user).tranche(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);
            // Oracle will be set in each test with the specific price
        });

        it('Should return projected rates from current oracle', async function () {
            await oracle.setRoundData(101000000n, await time.latest());

            const [srRate, jrRate, oraclePrice] = await market.previewSettlement();

            expect(oraclePrice).to.equal(parseEther('1.01'));
            expect(srRate).to.be.gt(0n);
            expect(jrRate).to.be.gt(0n);
        });

        it('Should not modify state', async function () {
            await oracle.setRoundData(101000000n, await time.latest());

            // Call preview multiple times
            await market.previewSettlement();
            await market.previewSettlement();

            // Market should not be finalized
            expect(await market.finalized()).to.be.false;
            expect(await market.srRateUA()).to.equal(0n);
            expect(await market.jrRateUA()).to.equal(0n);
        });

        it('Should match finalize rates', async function () {
            await oracle.setRoundData(101000000n, await time.latest());

            const [previewSrRate, previewJrRate, previewPrice] = await market.previewSettlement();

            await market.connect(admin).finalize(previewPrice, parseEther('0.01'));

            const actualSrRate = await market.srRateUA();
            const actualJrRate = await market.jrRateUA();

            expect(actualSrRate).to.equal(previewSrRate);
            expect(actualJrRate).to.equal(previewJrRate);
        });

        context('Revert reasons', function () {
            it('Reverts when oracle returns invalid price', async function () {
                await oracle.setRoundData(0, await time.latest());

                await expect(market.previewSettlement()).to.be.revertedWithCustomError(market, 'OracleInvalidPrice');
            });

            it('Reverts when oracle price is stale', async function () {
                const currentTime = await time.latest();
                await oracle.setRoundData(100000000n, currentTime - 25 * 60 * 60);

                await expect(market.previewSettlement()).to.be.revertedWithCustomError(market, 'OracleStalePrice');
            });
        });
    });

    context('when redeeming post-finalization', function () {
        beforeEach(async function () {
            await market.connect(user).tranche(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);
            // Refresh oracle price after time increase
            await oracle.setRoundData(100000000n, await time.latest());
            await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));
        });

        it('Should allow senior redemption at calculated rate', async function () {
            const srToken = await ethers.getContractAt('TrancheToken', await market.srToken());
            const srBalance = await srToken.balanceOf(user.address);
            const srRate = await market.srRateUA();

            const expectedUa = (srBalance * srRate) / ONE;

            const userUaBefore = await ua.balanceOf(user.address);
            await market.connect(user).redeemSenior(srBalance, user.address);
            const userUaAfter = await ua.balanceOf(user.address);

            expect(userUaAfter - userUaBefore).to.equal(expectedUa);
        });

        it('Should allow junior redemption at calculated rate', async function () {
            const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
            const jrBalance = await jrToken.balanceOf(user.address);
            const jrRate = await market.jrRateUA();

            const expectedUa = (jrBalance * jrRate) / ONE;

            const userUaBefore = await ua.balanceOf(user.address);
            await market.connect(user).redeemJunior(jrBalance, user.address);
            const userUaAfter = await ua.balanceOf(user.address);

            expect(userUaAfter - userUaBefore).to.equal(expectedUa);
        });
    });

    context('invariant: no over-distribution', function () {
        it('Should not over-distribute across various price scenarios', async function () {
            const prices = [
                50000000n, // $0.50
                70000000n, // $0.70
                90000000n, // $0.90
                100000000n, // $1.00
                100300000n, // $1.003
                100500000n, // $1.005
                101000000n, // $1.01
                110000000n, // $1.10
                150000000n, // $1.50
            ];

            for (const price of prices) {
                // Deploy fresh market for each test
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                const testMarket = await MarketFactory.deploy(params);

                await ua.connect(user).approve(await testMarket.getAddress(), parseEther('100'));
                await testMarket.connect(user).tranche(parseEther('100'), user.address);
                await time.increase(TIME.MONTH + 1);

                // Set oracle price after time increase to avoid staleness
                await oracle.setRoundData(price, await time.latest());
                const oraclePriceWad = (price * parseEther('1')) / 100000000n;

                await testMarket.connect(admin).finalize(oraclePriceWad, parseEther('0.01'));

                const srRate = await testMarket.srRateUA();
                const jrRate = await testMarket.jrRateUA();
                const seniorRatio = await testMarket.seniorRatio();
                const uaQuantity = parseEther('100');

                const srSupply = mulDown(uaQuantity, seniorRatio);
                const jrSupply = uaQuantity - srSupply;
                const srDistributed = mulDown(srSupply, srRate);
                const jrDistributed = mulDown(jrSupply, jrRate);
                const totalDistributed = srDistributed + jrDistributed;

                expect(totalDistributed).to.be.lte(uaQuantity, `Over-distribution at price ${price}`);
            }
        });
    });

    describe('liquidation', function () {
        const liquidationMarketParams = async (
            uaAddress: string,
            oracleAddress: string,
            adminAddress: string,
            expiryOffset: number = TIME.MONTH
        ) => ({
            ua: uaAddress,
            expiry: (await time.latest()) + expiryOffset,
            seniorRatio: parseEther('0.8'),
            admin: adminAddress,
            priceFeed: oracleAddress,
            seniorFloor: parseEther('0.005'), // 0.5%
            seniorTarget: parseEther('0.01'), // 1%
            liquidationEnabled: true,
            liquidationBuffer: parseEther('0.025'), // 2.5%
            liquidationReward: parseEther('0.025'), // 2.5%
        });

        async function deployLiquidationFixture() {
            const [admin, user, other] = await ethers.getSigners();

            const ERC20MockFactory = await ethers.getContractFactory('ERC20Mock');
            const ua = await ERC20MockFactory.deploy('Underlying Asset', 'UA');
            await ua.waitForDeployment();

            const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
            const oracle = await MockOracleFactory.deploy(8, 'UA / USD');
            await oracle.waitForDeployment();

            await oracle.setRoundData(100000000n, await time.latest());

            const MarketFactory = await ethers.getContractFactory('TrancheMarket');
            const params = await liquidationMarketParams(
                await ua.getAddress(),
                await oracle.getAddress(),
                admin.address
            );
            const market = await MarketFactory.deploy(params);
            await market.waitForDeployment();

            await ua.mint(user.address, parseEther('1000'));
            await ua.connect(user).approve(await market.getAddress(), parseEther('1000'));

            return { market, ua, oracle, admin, user, other };
        }

        async function deployLiquidationWithTrancheFixture() {
            const base = await deployLiquidationFixture();
            await base.market.connect(base.user).tranche(parseEther('100'), base.user.address);
            return base;
        }

        describe('constructor', function () {
            it('Should deploy with liquidation enabled', async function () {
                const { market } = await loadFixture(deployLiquidationFixture);
                expect(await market.liquidationEnabled()).to.be.true;
                expect(await market.liquidationBuffer()).to.equal(parseEther('0.025'));
                expect(await market.liquidationReward()).to.equal(parseEther('0.025'));
            });

            it('Should deploy with liquidation disabled', async function () {
                const { ua, oracle, admin } = await loadFixture(deployLiquidationFixture);
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                const disabledMarket = await MarketFactory.deploy(params);

                expect(await disabledMarket.liquidationEnabled()).to.be.false;
                expect(await disabledMarket.liquidationPrice()).to.equal(0n);
            });

            it('Should calculate correct liquidation price', async function () {
                const { market } = await loadFixture(deployLiquidationFixture);

                const initialPrice = await market.initialPrice();
                const seniorRatio = await market.seniorRatio();
                const juniorRatio = await market.juniorRatio();
                const seniorFloor = await market.seniorFloor();
                const buffer = await market.liquidationBuffer();
                const reward = await market.liquidationReward();

                const expectedLiqPrice = mulDown(
                    initialPrice,
                    mulDown(seniorRatio, ONE + seniorFloor) + mulDown(juniorRatio, buffer + reward)
                );

                expect(await market.liquidationPrice()).to.equal(expectedLiqPrice);
            });

            it('Should accept zero buffer and reward', async function () {
                const { ua, oracle, admin } = await loadFixture(deployLiquidationFixture);
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = {
                    ua: await ua.getAddress(),
                    expiry: (await time.latest()) + TIME.MONTH,
                    seniorRatio: parseEther('0.8'),
                    admin: admin.address,
                    priceFeed: await oracle.getAddress(),
                    seniorFloor: parseEther('0.005'),
                    seniorTarget: parseEther('0.01'),
                    liquidationEnabled: true,
                    liquidationBuffer: 0n,
                    liquidationReward: 0n,
                };
                const zeroParamMarket = await MarketFactory.deploy(params);

                expect(await zeroParamMarket.liquidationBuffer()).to.equal(0n);
                expect(await zeroParamMarket.liquidationReward()).to.equal(0n);
                expect(await zeroParamMarket.liquidationPrice()).to.be.gt(0n);
            });

            it('Should accept max buffer (2.5%)', async function () {
                const { ua, oracle, admin } = await loadFixture(deployLiquidationFixture);
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = {
                    ua: await ua.getAddress(),
                    expiry: (await time.latest()) + TIME.MONTH,
                    seniorRatio: parseEther('0.8'),
                    admin: admin.address,
                    priceFeed: await oracle.getAddress(),
                    seniorFloor: parseEther('0.005'),
                    seniorTarget: parseEther('0.01'),
                    liquidationEnabled: true,
                    liquidationBuffer: parseEther('0.025'),
                    liquidationReward: 0n,
                };
                const maxBufferMarket = await MarketFactory.deploy(params);
                expect(await maxBufferMarket.liquidationBuffer()).to.equal(parseEther('0.025'));
            });

            it('Should accept max reward (2.5%)', async function () {
                const { ua, oracle, admin } = await loadFixture(deployLiquidationFixture);
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = {
                    ua: await ua.getAddress(),
                    expiry: (await time.latest()) + TIME.MONTH,
                    seniorRatio: parseEther('0.8'),
                    admin: admin.address,
                    priceFeed: await oracle.getAddress(),
                    seniorFloor: parseEther('0.005'),
                    seniorTarget: parseEther('0.01'),
                    liquidationEnabled: true,
                    liquidationBuffer: 0n,
                    liquidationReward: parseEther('0.025'),
                };
                const maxRewardMarket = await MarketFactory.deploy(params);
                expect(await maxRewardMarket.liquidationReward()).to.equal(parseEther('0.025'));
            });

            context('Revert reasons', function () {
                it('Reverts when buffer exceeds 2.5%', async function () {
                    const { ua, oracle, admin, market } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: parseEther('0.026'),
                        liquidationReward: 0n,
                    };

                    await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(
                        market,
                        'LiquidationInvalidBuffer'
                    );
                });

                it('Reverts when reward exceeds 2.5%', async function () {
                    const { ua, oracle, admin, market } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: 0n,
                        liquidationReward: parseEther('0.026'),
                    };

                    await expect(MarketFactory.deploy(params)).to.be.revertedWithCustomError(
                        market,
                        'LiquidationInvalidReward'
                    );
                });
            });
        });

        describe('liquidate', function () {
            it('Should liquidate when price below threshold', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const tx = await market.connect(admin).liquidate();

                await expect(tx).to.emit(market, 'Liquidate');
                expect(await market.finalized()).to.be.true;
            });

            it('Should set jrRateUA to 0', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();
                expect(await market.jrRateUA()).to.equal(0n);
            });

            it('Should transfer reward to admin', async function () {
                const { market, ua, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
                const jrSupply = await jrToken.totalSupply();
                const rewardRate = await market.liquidationReward();
                const expectedReward = mulDown(jrSupply, rewardRate);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const adminBalanceBefore = await ua.balanceOf(admin.address);
                await market.connect(admin).liquidate();
                const adminBalanceAfter = await ua.balanceOf(admin.address);

                expect(adminBalanceAfter - adminBalanceBefore).to.equal(expectedReward);
            });

            it('Should calculate correct srRateUA', async function () {
                const { market, ua, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const uaQuantity = await ua.balanceOf(await market.getAddress());
                const srToken = await ethers.getContractAt('TrancheToken', await market.srToken());
                const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
                const srSupply = await srToken.totalSupply();
                const jrSupply = await jrToken.totalSupply();
                const rewardRate = await market.liquidationReward();
                const liquidatorReward = mulDown(jrSupply, rewardRate);
                const remainingUA = uaQuantity - liquidatorReward;
                const expectedSrRate = (remainingUA * ONE) / srSupply;

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();
                expect(await market.srRateUA()).to.equal(expectedSrRate);
            });

            it('Should emit Liquidate event', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const tx = await market.connect(admin).liquidate();
                await expect(tx)
                    .to.emit(market, 'Liquidate')
                    .withArgs(
                        belowLiqPrice,
                        liqPrice,
                        await market.srRateUA(),
                        await market.liquidationReward().then((r) => mulDown(parseEther('20'), r)),
                        admin.address
                    );
            });

            it('Should set finalized to true', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                expect(await market.finalized()).to.be.false;

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();
                expect(await market.finalized()).to.be.true;
            });

            it('Should allow senior redemption after liquidation', async function () {
                const { market, ua, oracle, admin, user } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();

                const srToken = await ethers.getContractAt('TrancheToken', await market.srToken());
                const srBalance = await srToken.balanceOf(user.address);
                const srRate = await market.srRateUA();
                const expectedUa = mulDown(srBalance, srRate);

                const userUaBefore = await ua.balanceOf(user.address);
                await market.connect(user).redeemSenior(srBalance, user.address);
                const userUaAfter = await ua.balanceOf(user.address);

                expect(userUaAfter - userUaBefore).to.equal(expectedUa);
            });

            it('Should give junior 0 on redemption', async function () {
                const { market, ua, oracle, admin, user } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();

                const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
                const jrBalance = await jrToken.balanceOf(user.address);

                const userUaBefore = await ua.balanceOf(user.address);
                await market.connect(user).redeemJunior(jrBalance, user.address);
                const userUaAfter = await ua.balanceOf(user.address);

                expect(userUaAfter - userUaBefore).to.equal(0n);
            });

            context('Edge cases', function () {
                it('Should liquidate at exact threshold price minus 1 wei', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const justBelowLiqPrice = liqPrice - 1n;
                    const oracle8Dec = (justBelowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.emit(market, 'Liquidate');
                });

                it('Should work with zero buffer', async function () {
                    const { ua, oracle, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: 0n,
                        liquidationReward: parseEther('0.025'),
                    };
                    const zeroBufferMarket = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await zeroBufferMarket.getAddress(), parseEther('100'));
                    await zeroBufferMarket.connect(user).tranche(parseEther('100'), user.address);

                    const liqPrice = await zeroBufferMarket.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(zeroBufferMarket.connect(admin).liquidate()).to.emit(zeroBufferMarket, 'Liquidate');
                });

                it('Should work with zero reward', async function () {
                    const { ua, oracle, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: parseEther('0.025'),
                        liquidationReward: 0n,
                    };
                    const zeroRewardMarket = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await zeroRewardMarket.getAddress(), parseEther('100'));
                    await zeroRewardMarket.connect(user).tranche(parseEther('100'), user.address);

                    const adminBalanceBefore = await ua.balanceOf(admin.address);

                    const liqPrice = await zeroRewardMarket.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await zeroRewardMarket.connect(admin).liquidate();

                    const adminBalanceAfter = await ua.balanceOf(admin.address);
                    expect(adminBalanceAfter).to.equal(adminBalanceBefore);
                });

                it('Should work with both zero buffer and reward', async function () {
                    const { ua, oracle, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: 0n,
                        liquidationReward: 0n,
                    };
                    const zeroBothMarket = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await zeroBothMarket.getAddress(), parseEther('100'));
                    await zeroBothMarket.connect(user).tranche(parseEther('100'), user.address);

                    const liqPrice = await zeroBothMarket.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(zeroBothMarket.connect(admin).liquidate()).to.emit(zeroBothMarket, 'Liquidate');
                });

                it('Should handle 6 decimal oracle', async function () {
                    const { ua, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
                    const oracle6 = await MockOracleFactory.deploy(6, 'UA / USD');
                    await oracle6.setRoundData(1000000n, await time.latest());

                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle6.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: parseEther('0.025'),
                        liquidationReward: parseEther('0.025'),
                    };
                    const market6 = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await market6.getAddress(), parseEther('100'));
                    await market6.connect(user).tranche(parseEther('100'), user.address);

                    const liqPrice = await market6.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle6Dec = (belowLiqPrice * 1000000n) / ONE;
                    await oracle6.setRoundData(oracle6Dec, await time.latest());

                    await expect(market6.connect(admin).liquidate()).to.emit(market6, 'Liquidate');
                });

                it('Should handle 8 decimal oracle', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.emit(market, 'Liquidate');
                });

                it('Should handle 18 decimal oracle', async function () {
                    const { ua, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MockOracleFactory = await ethers.getContractFactory('MockChainlinkAggregator');
                    const oracle18 = await MockOracleFactory.deploy(18, 'UA / USD');
                    await oracle18.setRoundData(parseEther('1'), await time.latest());

                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = {
                        ua: await ua.getAddress(),
                        expiry: (await time.latest()) + TIME.MONTH,
                        seniorRatio: parseEther('0.8'),
                        admin: admin.address,
                        priceFeed: await oracle18.getAddress(),
                        seniorFloor: parseEther('0.005'),
                        seniorTarget: parseEther('0.01'),
                        liquidationEnabled: true,
                        liquidationBuffer: parseEther('0.025'),
                        liquidationReward: parseEther('0.025'),
                    };
                    const market18 = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await market18.getAddress(), parseEther('100'));
                    await market18.connect(user).tranche(parseEther('100'), user.address);

                    const liqPrice = await market18.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    await oracle18.setRoundData(belowLiqPrice, await time.latest());

                    await expect(market18.connect(admin).liquidate()).to.emit(market18, 'Liquidate');
                });
            });

            context('Revert reasons', function () {
                it('Reverts when liquidation not enabled', async function () {
                    const { ua, oracle, admin, user } = await loadFixture(deployLiquidationFixture);
                    const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                    const params = await defaultMarketParams(
                        await ua.getAddress(),
                        await oracle.getAddress(),
                        admin.address
                    );
                    const disabledMarket = await MarketFactory.deploy(params);

                    await ua.connect(user).approve(await disabledMarket.getAddress(), parseEther('100'));
                    await disabledMarket.connect(user).tranche(parseEther('100'), user.address);

                    await oracle.setRoundData(50000000n, await time.latest());

                    await expect(disabledMarket.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        disabledMarket,
                        'LiquidationNotEnabled'
                    );
                });

                it('Reverts when price above threshold', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    await oracle.setRoundData(100000000n, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'LiquidationConditionNotMet'
                    );
                });

                it('Reverts when price exactly at threshold', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const oracle8Dec = (liqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'LiquidationConditionNotMet'
                    );
                });

                it('Reverts when called after expiry', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    await time.increase(TIME.MONTH + 1);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'LiquidationAfterExpiry'
                    );
                });

                it('Reverts when already finalized', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);
                    await time.increase(TIME.MONTH + 1);
                    await oracle.setRoundData(100000000n, await time.latest());
                    await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'LiquidationAfterExpiry'
                    );
                });

                it('Reverts when already liquidated', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await market.connect(admin).liquidate();

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'TrancheMarketAlreadyFinalized'
                    );
                });

                it('Reverts when called by non-admin', async function () {
                    const { market, oracle, other } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(other).liquidate()).to.be.revertedWithCustomError(market, 'OnlyAdmin');
                });

                it('Reverts when oracle price is stale', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    const currentTime = await time.latest();
                    await oracle.setRoundData(oracle8Dec, currentTime - 25 * 60 * 60);

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'OracleStalePrice'
                    );
                });

                it('Reverts when oracle price is invalid', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    await oracle.setRoundData(0, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'OracleInvalidPrice'
                    );
                });

                it('Reverts when no UA in contract', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'SettlementZeroQuantity'
                    );
                });

                it('Reverts finalize() after liquidation', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    const liqPrice = await market.liquidationPrice();
                    const belowLiqPrice = (liqPrice * 99n) / 100n;
                    const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                    await oracle.setRoundData(oracle8Dec, await time.latest());

                    await market.connect(admin).liquidate();

                    await time.increase(TIME.MONTH + 1);
                    await oracle.setRoundData(100000000n, await time.latest());

                    await expect(
                        market.connect(admin).finalize(parseEther('1'), parseEther('0.01'))
                    ).to.be.revertedWithCustomError(market, 'TrancheMarketAlreadyFinalized');
                });

                it('Reverts liquidate() after finalize()', async function () {
                    const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                    await time.increase(TIME.MONTH + 1);
                    await oracle.setRoundData(100000000n, await time.latest());
                    await market.connect(admin).finalize(parseEther('1'), parseEther('0.01'));

                    await expect(market.connect(admin).liquidate()).to.be.revertedWithCustomError(
                        market,
                        'LiquidationAfterExpiry'
                    );
                });
            });
        });

        describe('previewLiquidation', function () {
            it('Should return canLiquidate=true when conditions met', async function () {
                const { market, oracle } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const [canLiquidate] = await market.previewLiquidation();
                expect(canLiquidate).to.be.true;
            });

            it('Should return canLiquidate=false when price above', async function () {
                const { market, oracle } = await loadFixture(deployLiquidationWithTrancheFixture);

                await oracle.setRoundData(100000000n, await time.latest());

                const [canLiquidate] = await market.previewLiquidation();
                expect(canLiquidate).to.be.false;
            });

            it('Should return canLiquidate=false after expiry', async function () {
                const { market, oracle } = await loadFixture(deployLiquidationWithTrancheFixture);

                await time.increase(TIME.MONTH + 1);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const [canLiquidate] = await market.previewLiquidation();
                expect(canLiquidate).to.be.false;
            });

            it('Should return canLiquidate=false when disabled', async function () {
                const { ua, oracle, admin, user } = await loadFixture(deployLiquidationFixture);
                const MarketFactory = await ethers.getContractFactory('TrancheMarket');
                const params = await defaultMarketParams(
                    await ua.getAddress(),
                    await oracle.getAddress(),
                    admin.address
                );
                const disabledMarket = await MarketFactory.deploy(params);

                await ua.connect(user).approve(await disabledMarket.getAddress(), parseEther('100'));
                await disabledMarket.connect(user).tranche(parseEther('100'), user.address);

                await oracle.setRoundData(50000000n, await time.latest());

                const [canLiquidate] = await disabledMarket.previewLiquidation();
                expect(canLiquidate).to.be.false;
            });

            it('Should return correct liquidator reward preview', async function () {
                const { market, oracle } = await loadFixture(deployLiquidationWithTrancheFixture);

                const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
                const jrSupply = await jrToken.totalSupply();
                const rewardRate = await market.liquidationReward();
                const expectedReward = mulDown(jrSupply, rewardRate);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const [, , , , liquidatorReward] = await market.previewLiquidation();
                expect(liquidatorReward).to.equal(expectedReward);
            });

            it('Should return correct srRateUA preview', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                const [, , , previewSrRate] = await market.previewLiquidation();

                await market.connect(admin).liquidate();

                expect(await market.srRateUA()).to.equal(previewSrRate);
            });
        });

        describe('invariants', function () {
            it('Should not over-distribute on liquidation', async function () {
                const { market, ua, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const uaQuantityBefore = await ua.balanceOf(await market.getAddress());

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();

                const srToken = await ethers.getContractAt('TrancheToken', await market.srToken());
                const jrToken = await ethers.getContractAt('TrancheToken', await market.jrToken());
                const srSupply = await srToken.totalSupply();
                const jrSupply = await jrToken.totalSupply();
                const srRate = await market.srRateUA();
                const jrRate = await market.jrRateUA();

                const srDistributed = mulDown(srSupply, srRate);
                const jrDistributed = mulDown(jrSupply, jrRate);
                const adminReward = await ua.balanceOf(admin.address);
                const totalDistributed = srDistributed + jrDistributed + adminReward;

                expect(totalDistributed).to.be.lte(uaQuantityBefore);
            });

            it('Senior redemption should receive >= floor value', async function () {
                const { market, oracle, admin } = await loadFixture(deployLiquidationWithTrancheFixture);

                const srToken = await ethers.getContractAt('TrancheToken', await market.srToken());
                const srSupply = await srToken.totalSupply();
                const seniorFloor = await market.seniorFloor();
                const minSeniorValue = mulDown(srSupply, ONE + seniorFloor);

                const liqPrice = await market.liquidationPrice();
                const belowLiqPrice = (liqPrice * 99n) / 100n;
                const oracle8Dec = (belowLiqPrice * 100000000n) / ONE;
                await oracle.setRoundData(oracle8Dec, await time.latest());

                await market.connect(admin).liquidate();

                const srRate = await market.srRateUA();
                const seniorTotalValue = mulDown(srSupply, srRate);

                expect(seniorTotalValue).to.be.gte(minSeniorValue - 1n);
            });
        });
    });
});
