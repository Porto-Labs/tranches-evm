import { expect } from 'chai';
import { ethers } from 'hardhat';
import { loadFixture, time } from '@nomicfoundation/hardhat-network-helpers';
import { SignerWithAddress } from '@nomicfoundation/hardhat-ethers/signers';
import { TrancheMarket, ERC20Mock, MockChainlinkAggregator } from '../../typechain-types';
import { TIME } from '../utils';

const { parseEther, ZeroAddress } = ethers;

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
        it('Should scale 8 decimal price to WAD correctly', async function () {
            // Tokenize to have UA in the market
            await market.connect(user).tokenize(parseEther('100'), user.address);

            // Move past expiry
            await time.increase(TIME.MONTH + 1);

            // Set oracle to $1.50 (150000000 in 8 decimals) - after time increase to avoid staleness
            await oracle.setRoundData(150000000n, await time.latest());

            // Preview should return price in WAD
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
            await market18.connect(user).tokenize(parseEther('100'), user.address);
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
            await market6.connect(user).tokenize(parseEther('100'), user.address);
            await time.increase(TIME.MONTH + 1);

            // Refresh oracle price after time increase
            await oracle6.setRoundData(2000000n, await time.latest());

            const [, , oraclePrice] = await market6.previewSettlement();
            expect(oraclePrice).to.equal(parseEther('2'));
        });
    });

    describe('finalize', function () {
        beforeEach(async function () {
            // Tokenize to have UA in the market
            await market.connect(user).tokenize(parseEther('100'), user.address);
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
            await market.connect(user).tokenize(parseEther('100'), user.address);
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
            await market.connect(user).tokenize(parseEther('100'), user.address);
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
            await market.connect(user).tokenize(parseEther('100'), user.address);
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
        const mulDown = (a: bigint, b: bigint): bigint => (a * b) / ONE;

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
                await testMarket.connect(user).tokenize(parseEther('100'), user.address);
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
});
