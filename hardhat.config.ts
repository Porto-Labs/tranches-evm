import '@nomicfoundation/hardhat-chai-matchers';
import '@nomiclabs/hardhat-ethers';
import '@nomiclabs/hardhat-etherscan';
import '@typechain/hardhat';
import 'hardhat-gas-reporter';
import 'solidity-coverage';
import 'hardhat-contract-sizer';
import { HardhatUserConfig } from 'hardhat/types';

const config: HardhatUserConfig = {
    paths: {
        sources: './contracts',
        tests: './test',
        artifacts: './build/artifacts',
        cache: './build/cache',
    },
    solidity: {
        compilers: [
            {
                version: '0.8.23',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1000000,
                    },
                    evmVersion: 'shanghai',
                },
            },
        ],
    },
    typechain: {
        outDir: 'typechain-types',
        target: 'ethers-v5',
    },
    contractSizer: {
        disambiguatePaths: false,
        runOnCompile: false,
        strict: true,
        only: [],
    },
    networks: {
        hardhat: {
            allowUnlimitedContractSize: false,
        },
    },
};

export default config;
