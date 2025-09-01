// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract VaultTest is Test {
    StableYieldVault public vault;
    MockUSDC public usdc;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public feeRecipient = makeAddr("feeRecipient");
    
    uint256 public constant INITIAL_DEPOSIT = 1000e6; // 1000 USDC
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Deploy vault
        vm.prank(owner);
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Stable Yield Vault",
            "SYV",
            owner,
            feeRecipient,
            100, // 1% management fee
            1000 // 10% performance fee
        );
        
        // Give users some USDC
        usdc.mint(user1, 10_000e6);
        usdc.mint(user2, 10_000e6);
    }
    
    function testInitialState() public {
        assertEq(vault.name(), "Stable Yield Vault");
        assertEq(vault.symbol(), "SYV");
        assertEq(vault.decimals(), 6);
        assertEq(address(vault.asset()), address(usdc));
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.totalSupply(), 0);
    }
    
    function testDeposit() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, user1);
        
        assertEq(shares, INITIAL_DEPOSIT); // 1:1 ratio initially
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT);
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT);
        vm.stopPrank();
    }
    
    function testMint() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        
        uint256 assets = vault.mint(INITIAL_DEPOSIT, user1);
        
        assertEq(assets, INITIAL_DEPOSIT); // 1:1 ratio initially
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT);
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
        vm.stopPrank();
    }
    
    function testWithdraw() public {
        // First deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        
        // Then withdraw
        uint256 withdrawAmount = 500e6;
        uint256 sharesBurned = vault.withdraw(withdrawAmount, user1, user1);
        
        assertEq(sharesBurned, withdrawAmount); // 1:1 ratio
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT - withdrawAmount);
        assertEq(usdc.balanceOf(user1), 10_000e6 - INITIAL_DEPOSIT + withdrawAmount);
        vm.stopPrank();
    }
    
    function testRedeem() public {
        // First deposit
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        
        // Then redeem
        uint256 redeemShares = 500e6;
        uint256 assetsReceived = vault.redeem(redeemShares, user1, user1);
        
        assertEq(assetsReceived, redeemShares); // 1:1 ratio
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT - redeemShares);
        vm.stopPrank();
    }
    
    function testMultipleDepositors() public {
        // User1 deposits
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // User2 deposits
        vm.startPrank(user2);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user2);
        vm.stopPrank();
        
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT * 2);
        assertEq(vault.totalSupply(), INITIAL_DEPOSIT * 2);
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT);
        assertEq(vault.balanceOf(user2), INITIAL_DEPOSIT);
    }
    
    function testPauseUnpause() public {
        vm.startPrank(owner);
        
        // Grant pauser role to owner
        vault.accessController().grantRole(vault.accessController().PAUSER_ROLE(), owner);
        
        // Pause vault
        vault.pause();
        vm.stopPrank();
        
        // Try to deposit while paused - should fail
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vm.expectRevert("StableYieldVault: paused or shutdown");
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Unpause
        vm.prank(owner);
        vault.unpause();
        
        // Now deposit should work
        vm.startPrank(user1);
        vault.deposit(INITIAL_DEPOSIT, user1);
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT);
        vm.stopPrank();
    }
    
    function testEmergencyShutdown() public {
        // First deposit some funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Emergency shutdown
        vm.prank(owner);
        vault.emergencyShutdownVault();
        
        // Deposits should fail
        vm.startPrank(user2);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vm.expectRevert("StableYieldVault: paused or shutdown");
        vault.deposit(INITIAL_DEPOSIT, user2);
        vm.stopPrank();
        
        // But withdrawals should still work
        vm.startPrank(user1);
        vault.withdraw(500e6, user1, user1);
        assertEq(vault.balanceOf(user1), INITIAL_DEPOSIT - 500e6);
        vm.stopPrank();
    }
    
    function testRoundingEdgeCases() public {
        // Test small deposits and withdrawals
        vm.startPrank(user1);
        usdc.approve(address(vault), 1e6);
        
        // Deposit 1 USDC
        uint256 shares = vault.deposit(1e6, user1);
        assertEq(shares, 1e6);
        
        // Withdraw 0.5 USDC
        uint256 sharesBurned = vault.withdraw(0.5e6, user1, user1);
        assertEq(sharesBurned, 0.5e6);
        
        vm.stopPrank();
    }
    
    function testPreviewFunctions() public {
        // Test preview functions with empty vault
        assertEq(vault.previewDeposit(1000e6), 1000e6);
        assertEq(vault.previewMint(1000e6), 1000e6);
        assertEq(vault.previewWithdraw(1000e6), 1000e6);
        assertEq(vault.previewRedeem(1000e6), 1000e6);
        
        // Deposit some funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Test preview functions with funds
        assertEq(vault.previewDeposit(1000e6), 1000e6);
        assertEq(vault.previewMint(1000e6), 1000e6);
        assertEq(vault.previewWithdraw(500e6), 500e6);
        assertEq(vault.previewRedeem(500e6), 500e6);
    }
    
    function testVaultMetrics() public {
        // Test initial metrics
        (
            uint256 totalAssets,
            uint256 strategyAssets,
            uint256 idleAssets,
            uint256 totalShares,
            uint256 sharePrice,
            bool isPaused,
            bool isShutdown
        ) = vault.getVaultMetrics();
        
        assertEq(totalAssets, 0);
        assertEq(strategyAssets, 0);
        assertEq(idleAssets, 0);
        assertEq(totalShares, 0);
        assertEq(sharePrice, 1e18); // 1:1 ratio
        assertFalse(isPaused);
        assertFalse(isShutdown);
        
        // Deposit and test again
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        (totalAssets, strategyAssets, idleAssets, totalShares, sharePrice, isPaused, isShutdown) = vault.getVaultMetrics();
        
        assertEq(totalAssets, INITIAL_DEPOSIT);
        assertEq(strategyAssets, 0); // No strategies added yet
        assertEq(idleAssets, INITIAL_DEPOSIT);
        assertEq(totalShares, INITIAL_DEPOSIT);
        assertEq(sharePrice, 1e18); // Still 1:1 ratio
    }
}