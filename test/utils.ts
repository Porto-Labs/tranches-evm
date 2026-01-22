import { time } from '@nomicfoundation/hardhat-network-helpers';

/**
 * Re-export time helpers from hardhat-network-helpers for convenience
 */
export const latest = time.latest;
export const increaseTo = time.increaseTo;
export const increase = time.increase;
export const setNextBlockTimestamp = time.setNextBlockTimestamp;

/**
 * Time constants for convenience
 */
export const TIME = {
    SECOND: 1,
    MINUTE: 60,
    HOUR: 60 * 60,
    DAY: 24 * 60 * 60,
    WEEK: 7 * 24 * 60 * 60,
    MONTH: 30 * 24 * 60 * 60,
    YEAR: 365 * 24 * 60 * 60,
};
