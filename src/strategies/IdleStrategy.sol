// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseStrategy} from "./BaseStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {FixedPointMathLib} from "../lib/FixedPointMathLib.sol";

/**
 * @title IdleStrategy
 * @notice Mock strategy that accrues fixed interest on deposited USDC
 * @dev Used for testing and as a baseline yield source
 */
contract IdleStrategy is BaseStrategy {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    uint256 public annualRateBps = 400;  // 4% annual rate
    uint256 public lastAccrual;          // Last time interest was accrued
    uint256 public accruedInterest;      // Total interest accrued but not yet distributed

    uint256 private _totalAssets;        // Internal asset tracking

    uint256 public constant SECONDS_PER_YEAR = 365.25 days;
    uint256 public constant MAX_RATE_BPS = 2000; // 20% max annual rate

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset,
        address _vault,
        uint256 _maxCap,
        uint256 _annualRateBps
    ) BaseStrategy(_asset, _vault, _maxCap) {
        require(_annualRateBps <= MAX_RATE_BPS, "IdleStrategy: rate too high");
        
        annualRateBps = _annualRateBps;
        lastAccrual = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total USDC value including accrued interest
     */
    function totalAssets() public view override returns (uint256) {
        return _totalAssets + _calculateAccruedInterest();
    }

    /**
     * @notice Estimate output (always 1:1 for idle strategy)
     */
    function estimateWithdrawOutput(uint256 assets) public pure override returns (uint256) {
        return assets; // 1:1 redemption always
    }

    /*//////////////////////////////////////////////////////////////
                          STRATEGY IMPLEMENTATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice "Deposit" USDC (just hold it and start accruing interest)
     */
    function _deposit(uint256 assets) internal override returns (uint256 shares) {
        _accrueInterest();
        _totalAssets += assets;
        shares = assets;
    }

    /**
     * @notice "Withdraw" USDC (reduce balance and accrue final interest)
     */
    function _withdraw(uint256 assets) internal override returns (uint256 shares) {
        _accrueInterest();
        require(assets <= _totalAssets, "IdleStrategy: insufficient assets");
        
        _totalAssets -= assets;
        shares = assets;
    }

    /*//////////////////////////////////////////////////////////////
                           INTEREST ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate interest accrued since last accrual
     */
    function _calculateAccruedInterest() internal view returns (uint256) {
        if (_totalAssets == 0 || annualRateBps == 0) return 0;
        
        uint256 timeDelta = block.timestamp - lastAccrual;
        if (timeDelta == 0) return 0;
        
        // Calculate compound interest: P * (1 + r)^t - P
        // Simplified to linear for small time periods: P * r * t
        uint256 interestEarned = _totalAssets
            .mulDivDown(annualRateBps, BPS_SCALE)
            .mulDivDown(timeDelta, SECONDS_PER_YEAR);
            
        return interestEarned;
    }

    /**
     * @notice Accrue interest and update balances
     */
    function _accrueInterest() internal {
        uint256 newInterest = _calculateAccruedInterest();
        if (newInterest > 0) {
            accruedInterest += newInterest;
            _totalAssets += newInterest;
        }
        lastAccrual = block.timestamp;
    }

    /**
     * @notice Manually trigger interest accrual (for testing/reporting)
     */
    function accrueInterest() external returns (uint256 interestEarned) {
        interestEarned = _calculateAccruedInterest();
        _accrueInterest();
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get current annual rate
     */
    function getCurrentSupplyRate() external view returns (uint256) {
        return annualRateBps;
    }

    /**
     * @notice Get strategy-specific metrics
     */
    function getStrategyMetrics() external view returns (
        uint256 principalBalance,
        uint256 interestAccrued,
        uint256 currentRate,
        uint256 timeSinceLastAccrual,
        uint256 pendingInterest
    ) {
        principalBalance = _totalAssets;
        interestAccrued = accruedInterest;
        currentRate = annualRateBps;
        timeSinceLastAccrual = block.timestamp - lastAccrual;
        pendingInterest = _calculateAccruedInterest();
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Update the annual interest rate
     */
    function setAnnualRate(uint256 _annualRateBps) external onlyVault {
        require(_annualRateBps <= MAX_RATE_BPS, "IdleStrategy: rate too high");
        
        // Accrue interest at old rate first
        _accrueInterest();
        
        annualRateBps = _annualRateBps;
    }

    /*//////////////////////////////////////////////////////////////
                             EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency withdraw all funds (no-op for idle strategy)
     */
    function emergencyWithdrawAll() external onlyVault whenPaused returns (uint256) {
        _accrueInterest();
        uint256 balance = asset.balanceOf(address(this));
        
        if (balance > 0) {
            asset.safeTransfer(vault, balance);
        }
        
        totalDebt = 0;
        return balance;
    }

    /*//////////////////////////////////////////////////////////////
                            SIMULATION HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Fast-forward time for testing (TESTING ONLY)
     * @dev This function should be removed in production
     */
    function fastForward(uint256 seconds_) external onlyVault {
        lastAccrual += seconds_;
    }

    /**
     * @notice Simulate yield over time period
     */
    function simulateYield(uint256 timeSeconds) external view returns (uint256 expectedYield) {
        if (_totalAssets == 0) return 0;
        
        expectedYield = _totalAssets
            .mulDivDown(annualRateBps, BPS_SCALE)
            .mulDivDown(timeSeconds, SECONDS_PER_YEAR);
    }
}