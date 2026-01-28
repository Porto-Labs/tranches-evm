import '@nomicfoundation/hardhat-chai-matchers';
import '@nomicfoundation/hardhat-ethers';
import '@nomicfoundation/hardhat-verify';
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
                version: '0.8.28',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 1000000,
                    },
                    evmVersion: 'cancun',
                },
            },
        ],
    },
    typechain: {
        outDir: 'typechain-types',
        target: 'ethers-v6',
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
