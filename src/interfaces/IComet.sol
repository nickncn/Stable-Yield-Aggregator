// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

/**
 * @title IComet
 * @notice Minimal Compound V3 (Comet) interface for USDC strategy
 * @dev Production would use official Compound interfaces
 */
interface IComet is IERC20 {
    function supply(address asset, uint256 amount) external;
    function withdraw(address asset, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function baseToken() external view returns (address);
    function baseTrackingSupplySpeed() external view returns (uint256);
    function baseTrackingBorrowSpeed() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrow() external view returns (uint256);
    function getUtilization() external view returns (uint256);
    function getSupplyRate(uint256 utilization) external view returns (uint64);
    function getBorrowRate(uint256 utilization) external view returns (uint64);

    struct AssetInfo {
        uint8 offset;
        address asset;
        address priceFeed;
        uint64 scale;
        uint64 borrowCollateralFactor;
        uint64 liquidateCollateralFactor;
        uint64 liquidationFactor;
        uint128 supplyCap;
    }

    function getAssetInfo(uint8 i) external view returns (AssetInfo memory);
    function numAssets() external view returns (uint8);
}

// Mainnet Addresses 
// cUSDCv3: 0xc3d688B66703497DAA19211EEdff47f25384cdc3
// USDC: 0xA0b86a33E6417c5b2C1c00b1A3B35a0d8C3c8c5d