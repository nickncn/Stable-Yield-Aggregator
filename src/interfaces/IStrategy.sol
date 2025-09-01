// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

/**
 * @title IStrategy
 * @notice Standard interface for yield strategies
 */
interface IStrategy {
    /// @notice The underlying asset (USDC)
    function asset() external view returns (IERC20);
    
    /// @notice Current total assets controlled by this strategy
    function totalAssets() external view returns (uint256);
    
    /// @notice Maximum amount that can be deposited
    function maxDeposit(address receiver) external view returns (uint256);
    
    /// @notice Maximum amount that can be withdrawn
    function maxWithdraw(address owner) external view returns (uint256);
    
    /// @notice Deposit assets into the strategy
    function deposit(uint256 amount) external returns (uint256 shares);
    
    /// @notice Withdraw assets from the strategy
    function withdraw(uint256 amount) external returns (uint256 shares);
    
    /// @notice Report current status and accrue any fees
    function report() external returns (uint256 gain, uint256 loss);

    /// @notice Check if strategy is paused
    function paused() external view returns (bool);

    /// @notice Emergency pause
    function pause() external;
    
    /// @notice Resume operations  
    function unpause() external;

    // Events
    event Deposit(address indexed caller, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, uint256 assets, uint256 shares);
    event Report(uint256 gain, uint256 loss, uint256 totalAssets);
    event Paused(address account);
    event Unpaused(address account);
}