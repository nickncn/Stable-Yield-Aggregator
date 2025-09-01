// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IComet} from "../interfaces/IComet.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";

/**
 * @title CompoundV3Strategy  
 * @notice Yield strategy that deposits USDC into Compound V3 (Comet) to earn lending interest
 * @dev Interacts with Compound V3 Comet contract for USDC lending
 */
contract CompoundV3Strategy is BaseStrategy {
    using SafeTransferLib for IERC20;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    IComet public immutable comet;

    // Mainnet addresses (for reference in production)  
    // USDC: 0xA0b86a33E6417c5b2C1c00b1A3B35a0d8C3c8c5d
    // cUSDCv3: 0xc3d688B66703497DAA19211EEdff47f25384cdc3

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset,
        address _vault,
        uint256 _maxCap,
        IComet _comet
    ) BaseStrategy(_asset, _vault, _maxCap) {
        require(address(_comet) != address(0), "CompoundV3Strategy: zero comet");
        require(_comet.baseToken() == address(_asset), "CompoundV3Strategy: asset mismatch");
        
        comet = _comet;
        
        // Approve Comet to spend USDC
        _asset.safeApprove(address(_comet), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            CORE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total USDC value controlled by this strategy (cUSDC balance)
     */
    function totalAssets() public view override returns (uint256) {
        return comet.balanceOf(address(this));
    }

    /**
     * @notice Estimate USDC output from withdrawing from Compound V3
     * @dev Compound V3 has 1:1 redemption for base asset, so estimate equals input
     */
    function estimateWithdrawOutput(uint256 assets) public view override returns (uint256) {
        // Compound V3 base tokens (USDC) are redeemable 1:1
        return assets;
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit USDC into Compound V3 to earn interest
     */
    function _deposit(uint256 assets) internal override returns (uint256 shares) {
        require(assets > 0, "CompoundV3Strategy: zero assets");
        
        // Supply USDC to Compound V3
        comet.supply(address(asset), assets);
        
        // Shares received should equal assets supplied (1:1 ratio for base asset)
        shares = assets;
    }

    /**
     * @notice Withdraw USDC from Compound V3
     */
    function _withdraw(uint256 assets) internal override returns (uint256 shares) {
        require(assets > 0, "CompoundV3Strategy: zero assets");
        require(assets <= totalAssets(), "CompoundV3Strategy: insufficient balance");
        
        // Withdraw USDC from Compound V3
        comet.withdraw(address(asset), assets);
        
        // Shares burned should equal assets withdrawn
        shares = assets;
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current Compound V3 supply rate for USDC
     */
    function getCurrentSupplyRate() external view returns (uint64 supplyRate) {
        try comet.getUtilization() returns (uint256 utilization) {
            supplyRate = comet.getSupplyRate(utilization);
        } catch {
            supplyRate = 0;
        }
    }

    /**
     * @notice Get strategy-specific metrics for monitoring
     */
    function getStrategyMetrics() external view returns (
        uint256 cTokenBalance,
        uint64 supplyRate,
        uint64 borrowRate,
        uint256 utilization,
        uint256 totalSupply,
        uint256 totalBorrow
    ) {
        cTokenBalance = comet.balanceOf(address(this));
        
        try comet.getUtilization() returns (uint256 util) {
            utilization = util;
            supplyRate = comet.getSupplyRate(util);
            borrowRate = comet.getBorrowRate(util);
        } catch {
            utilization = 0;
            supplyRate = 0;
            borrowRate = 0;
        }
        
        try comet.totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            totalSupply = 0;
        }
        
        try comet.totalBorrow() returns (uint256 borrow) {
            totalBorrow = borrow;
        } catch {
            totalBorrow = 0;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw all funds from Compound V3
     * @dev Only callable when paused, withdraws entire position
     */
    function emergencyWithdrawAll() external onlyVault whenPaused returns (uint256) {
        uint256 cTokenBalance = comet.balanceOf(address(this));
        if (cTokenBalance == 0) return 0;
        
        // Withdraw all USDC from Compound V3
        comet.withdraw(address(asset), cTokenBalance);
        
        // Transfer all USDC to vault
        uint256 usdcBalance = asset.balanceOf(address(this));
        if (usdcBalance > 0) {
            asset.safeTransfer(vault, usdcBalance);
        }
        
        totalDebt = 0;
        return cTokenBalance;
    }

    /*//////////////////////////////////////////////////////////////
                              COMPOUND REWARDS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Claim COMP rewards if available
     * @dev Compound V3 may distribute COMP tokens to suppliers
     */
    function claimRewards() external onlyKeeper returns (bool) {
        // In production, this would interact with Compound's Rewards contract
        // For now, this is a placeholder that always returns false
        return false;
    }
}