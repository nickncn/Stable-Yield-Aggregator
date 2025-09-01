// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/FixedPointMathLib.sol";

/**
 * @title BaseStrategy
 * @notice Abstract base implementation for yield strategies
 * @dev Provides common functionality: pausing, caps, slippage protection
 */
abstract contract BaseStrategy is IStrategy {
    using SafeTransferLib for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    IERC20 public immutable override asset;
    address public vault;
    address public keeper;

    bool public override paused;
    uint256 public maxCap;                    // Maximum assets this strategy can hold
    uint256 public minLiquidityOut = 9800;    // Min 98% output on withdrawals (BPS)
    uint256 public lastReport;                // Timestamp of last report
    uint256 public totalDebt;                 // Amount owed to vault

    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // 5% max slippage

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyVault() {
        require(msg.sender == vault, "BaseStrategy: caller not vault");
        _;
    }

    modifier onlyKeeper() {
        require(msg.sender == keeper || msg.sender == vault, "BaseStrategy: caller not keeper");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "BaseStrategy: paused");
        _;
    }

    modifier whenPaused() {
        require(paused, "BaseStrategy: not paused");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset, address _vault, uint256 _maxCap) {
        require(address(_asset) != address(0), "BaseStrategy: zero asset");
        require(_vault != address(0), "BaseStrategy: zero vault");
        require(_maxCap > 0, "BaseStrategy: zero cap");

        asset = _asset;
        vault = _vault;
        maxCap = _maxCap;
        keeper = _vault; // Default keeper is vault
        lastReport = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            CORE STRATEGY LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get total assets controlled by strategy
     * @dev Must be implemented by concrete strategies
     */
    function totalAssets() public view virtual override returns (uint256);

    /**
     * @notice Estimate expected output from withdrawing assets
     * @dev Must be implemented by concrete strategies  
     */
    function estimateWithdrawOutput(uint256 assets) public view virtual returns (uint256);

    /**
     * @notice Internal deposit implementation
     * @dev Must be implemented by concrete strategies
     */
    function _deposit(uint256 assets) internal virtual returns (uint256 shares);

    /**
     * @notice Internal withdraw implementation  
     * @dev Must be implemented by concrete strategies
     */
    function _withdraw(uint256 assets) internal virtual returns (uint256 shares);

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT/WITHDRAW LOGIC
    //////////////////////////////////////////////////////////////*/

    function maxDeposit(address) public view override returns (uint256) {
        if (paused) return 0;
        
        uint256 currentAssets = totalAssets();
        if (currentAssets >= maxCap) return 0;
        
        return maxCap - currentAssets;
    }

    function maxWithdraw(address) public view override returns (uint256) {
        if (paused) return 0;
        return totalAssets();
    }

    function deposit(uint256 assets) external override onlyVault whenNotPaused returns (uint256 shares) {
        require(assets > 0, "BaseStrategy: zero deposit");
        require(assets <= maxDeposit(msg.sender), "BaseStrategy: exceeds cap");

        // Transfer assets from vault
        asset.safeTransferFrom(msg.sender, address(this), assets);
        
        // Execute strategy-specific deposit
        shares = _deposit(assets);
        totalDebt += assets;

        emit Deposit(msg.sender, assets, shares);
    }

    function withdraw(uint256 assets) external override onlyVault returns (uint256 shares) {
        require(assets > 0, "BaseStrategy: zero withdraw");
        require(assets <= maxWithdraw(msg.sender), "BaseStrategy: insufficient assets");

        // Execute strategy-specific withdrawal
        shares = _withdraw(assets);
        
        // Verify slippage protection
        uint256 actualOutput = asset.balanceOf(address(this));
        uint256 minOutput = assets.mulDivDown(minLiquidityOut, BPS_SCALE);
        require(actualOutput >= minOutput, "BaseStrategy: slippage too high");

        // Transfer assets to vault
        totalDebt = totalDebt > assets ? totalDebt - assets : 0;
        asset.safeTransfer(msg.sender, actualOutput);

        emit Withdraw(msg.sender, actualOutput, shares);
    }

    /*//////////////////////////////////////////////////////////////
                             REPORTING LOGIC
    //////////////////////////////////////////////////////////////*/

    function report() external override onlyKeeper returns (uint256 gain, uint256 loss) {
        uint256 currentAssets = totalAssets();
        uint256 previousAssets = totalDebt;

        if (currentAssets > previousAssets) {
            gain = currentAssets - previousAssets;
        } else if (previousAssets > currentAssets) {
            loss = previousAssets - currentAssets;
            totalDebt = currentAssets;
        }

        lastReport = block.timestamp;
        emit Report(gain, loss, currentAssets);
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE FUNCTIONALITY
    //////////////////////////////////////////////////////////////*/

    function pause() external override onlyKeeper {
        require(!paused, "BaseStrategy: already paused");
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external override onlyKeeper {
        require(paused, "BaseStrategy: not paused");
        paused = false;
        emit Unpaused(msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setMaxCap(uint256 _maxCap) external onlyVault {
        require(_maxCap > 0, "BaseStrategy: zero cap");
        maxCap = _maxCap;
    }

    function setMinLiquidityOut(uint256 _minLiquidityOut) external onlyVault {
        require(_minLiquidityOut <= BPS_SCALE, "BaseStrategy: invalid slippage");
        require(_minLiquidityOut >= BPS_SCALE - MAX_SLIPPAGE_BPS, "BaseStrategy: slippage too high");
        minLiquidityOut = _minLiquidityOut;
    }

    function setKeeper(address _keeper) external onlyVault {
        require(_keeper != address(0), "BaseStrategy: zero keeper");
        keeper = _keeper;
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Emergency function to recover stuck tokens
     * @dev Only callable by vault, only for non-strategy tokens
     */
    function recoverToken(address token, uint256 amount) external onlyVault {
        require(token != address(asset), "BaseStrategy: cannot recover strategy asset");
        IERC20(token).safeTransfer(vault, amount);
    }

    /**
     * @notice Get strategy health metrics for monitoring
     */
    function getHealthMetrics() external view returns (
        uint256 currentAssets,
        uint256 currentDebt,  
        uint256 utilizationBps,
        uint256 timeSinceReport,
        bool isPaused
    ) {
        currentAssets = totalAssets();
        currentDebt = totalDebt;
        utilizationBps = maxCap > 0 ? currentAssets.mulDivDown(BPS_SCALE, maxCap) : 0;
        timeSinceReport = block.timestamp - lastReport;
        isPaused = paused;
    }
}