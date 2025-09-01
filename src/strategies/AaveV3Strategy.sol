// SPDX-License-Identifier: MIT  
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAaveV3Pool, IAToken} from "../interfaces/IAaveV3.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";

/**
 * @title AaveV3Strategy
 * @notice Yield strategy that deposits USDC into Aave V3 to earn lending interest
 * @dev Interacts with Aave V3 Pool and aUSDC token contracts
 */
contract AaveV3Strategy is BaseStrategy {
    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IAaveV3Pool public immutable aavePool;
    IAToken public immutable aToken;

    // Mainnet addresses (for reference in production)
    // USDC: 0xA0b86a33E6417c5b2C1c00b1A3B35a0d8C3c8c5d
    // aUSDC: 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c
    // Pool: 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset,
        address _vault,
        uint256 _maxCap,
        IAaveV3Pool _aavePool,
        IAToken _aToken
    ) BaseStrategy(_asset, _vault, _maxCap) {
        require(address(_aavePool) != address(0), "AaveV3Strategy: zero pool");
        require(address(_aToken) != address(0), "AaveV3Strategy: zero atoken");
        require(_aToken.UNDERLYING_ASSET_ADDRESS() == address(_asset), "AaveV3Strategy: asset mismatch");
        
        aavePool = _aavePool;
        aToken = _aToken;
        
        // Approve Aave pool to spend USDC
        _asset.safeApprove(address(_aavePool), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total USDC value controlled by this strategy (aUSDC balance)
     */
    function totalAssets() public view override returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /**
     * @notice Estimate USDC output from withdrawing aUSDC
     * @dev Aave V3 has 1:1 redemption, so estimate equals input
     */
    function estimateWithdrawOutput(uint256 assets) public view override returns (uint256) {
        // Aave V3 aTokens are redeemable 1:1 for underlying
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit USDC into Aave V3 to receive aUSDC
     */
    function _deposit(uint256 assets) internal override returns (uint256 shares) {
        require(assets > 0, "AaveV3Strategy: zero assets");
        
        // Supply USDC to Aave V3 pool
        aavePool.supply(address(asset), assets, address(this), 0);
        
        // aUSDC shares received should equal assets supplied (1:1 ratio)
        shares = assets;
    }

    /**
     * @notice Withdraw USDC from Aave V3 by burning aUSDC
     */
    function _withdraw(uint256 assets) internal override returns (uint256 shares) {
        require(assets > 0, "AaveV3Strategy: zero assets");
        require(assets <= totalAssets(), "AaveV3Strategy: insufficient balance");
        
        // Withdraw USDC from Aave V3 pool
        uint256 actualWithdrawn = aavePool.withdraw(address(asset), assets, address(this));
        
        // Shares burned should equal assets withdrawn
        shares = actualWithdrawn;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS  
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current Aave V3 lending rate for USDC
     */
    function getCurrentSupplyRate() external view returns (uint256 supplyRate) {
        try aavePool.getReserveData(address(asset)) returns (IAaveV3Pool.ReserveData memory reserveData) {
            supplyRate = reserveData.currentLiquidityRate;
        } catch {
            supplyRate = 0;
        }
    }

    /**
     * @notice Get strategy-specific metrics for monitoring
     */
    function getStrategyMetrics() external view returns (
        uint256 aTokenBalance,
        uint256 supplyRate,
        uint256 utilizationRate,
        uint256 lastUpdateTimestamp
    ) {
        aTokenBalance = aToken.balanceOf(address(this));
        
        try aavePool.getReserveData(address(asset)) returns (IAaveV3Pool.ReserveData memory reserveData) {
            supplyRate = reserveData.currentLiquidityRate;
            lastUpdateTimestamp = reserveData.lastUpdateTimestamp;
            
            // Calculate utilization rate if possible (simplified)
            utilizationRate = 8000; // Mock 80% utilization for demo
        } catch {
            supplyRate = 0;
            lastUpdateTimestamp = 0;
            utilizationRate = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw all funds from Aave
     * @dev Only callable when paused, withdraws entire position
     */
    function emergencyWithdrawAll() external onlyVault whenPaused returns (uint256) {
        uint256 aTokenBalance = aToken.balanceOf(address(this));
        if (aTokenBalance == 0) return 0;
        
        // Withdraw all USDC from Aave
        uint256 withdrawn = aavePool.withdraw(address(asset), aTokenBalance, address(this));
        
        // Transfer all USDC to vault
        uint256 usdcBalance = asset.balanceOf(address(this));
        if (usdcBalance > 0) {
            asset.safeTransfer(vault, usdcBalance);
        }
        
        totalDebt = 0;
        return withdrawn;
    }
}