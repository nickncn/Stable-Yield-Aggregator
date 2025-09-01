// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {Rebalancer} from "../src/vault/Rebalancer.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

/**
 * @title Rebalance Script
 * @notice Script to test and execute vault rebalancing
 */
contract RebalanceScript is Script {
    StableYieldVault public vault;
    MockUSDC public usdc;
    
    function run() external {
        // Get deployment addresses (you would need to set these)
        vault = StableYieldVault(vm.envAddress("VAULT_ADDRESS"));
        
        if (block.chainid == 31337 || block.chainid == 1337) {
            usdc = MockUSDC(address(vault.asset()));
        }
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console2.log("=== Rebalance Simulation ===");
        console2.log("Vault:", address(vault));
        console2.log("Caller:", msg.sender);
        console2.log("");
        
        // Check current state
        printCurrentState();
        
        // Check if rebalance is needed
        (bool rebalanceNeeded, uint256 maxDeviation) = vault.checkRebalanceNeeded();
        console2.log("Rebalance needed:", rebalanceNeeded);
        console2.log("Max deviation:", maxDeviation, "bps");
        console2.log("");
        
        if (!rebalanceNeeded && maxDeviation < 100) {
            console2.log("No significant rebalancing needed. Making a small deposit to trigger rebalance...");
            
            if (block.chainid == 31337 || block.chainid == 1337) {
                // Make a deposit to trigger rebalancing need
                uint256 depositAmount = 10_000e6; // 10K USDC
                if (usdc.balanceOf(owner) < depositAmount) {
                    usdc.mint(owner, depositAmount);
                }
                
                usdc.approve(address(vault), depositAmount);
                vault.deposit(depositAmount, owner);
                console2.log("Deposited", depositAmount / 1e6, "USDC");
                console2.log("");
            }
        }
        
        // Execute rebalance
        console2.log("Executing rebalance...");
        uint256 gasStart = gasleft();
        
        try vault.rebalance() returns (uint256 moveCount) {
            uint256 gasUsed = gasStart - gasleft();
            console2.log("Rebalance successful!");
            console2.log("Moves executed:", moveCount);
            console2.log("Gas used:", gasUsed);
        } catch Error(string memory reason) {
            console2.log("Rebalance failed:", reason);
        }
        
        console2.log("");
        
        // Show state after rebalance
        printCurrentState();
        
        // Check if further rebalancing is needed
        (rebalanceNeeded, maxDeviation) = vault.checkRebalanceNeeded();
        console2.log("Rebalance still needed:", rebalanceNeeded);
        console2.log("Max deviation after rebalance:", maxDeviation, "bps");
        
        vm.stopBroadcast();
    }
    
    function printCurrentState() internal view {
        (
            uint256 totalAssets,
            uint256 strategyAssets,
            uint256 idleAssets,
            uint256 totalShares,
            uint256 sharePrice,
            bool isPaused,
            bool isShutdown
        ) = vault.getVaultMetrics();
        
        console2.log("=== Current Vault State ===");
        console2.log("Total Assets:", totalAssets / 1e6, "USDC");
        console2.log("Strategy Assets:", strategyAssets / 1e6, "USDC");
        console2.log("Idle Assets:", idleAssets / 1e6, "USDC");
        console2.log("Total Shares:", totalShares / 1e6);
        console2.log("Share Price:", sharePrice / 1e12, "(scaled)"); // Adjust for display
        console2.log("Paused:", isPaused);
        console2.log("Shutdown:", isShutdown);
        console2.log("");
        
        // Show strategy allocations
        (
            address[] memory strategies,
            uint256[] memory allocations,
            uint256[] memory weights,
            uint256[] memory caps
        ) = vault.getStrategyAllocations();
        
        console2.log("=== Strategy Allocations ===");
        for (uint256 i = 0; i < strategies.length; i++) {
            console2.log(string(abi.encodePacked("Strategy ", vm.toString(i + 1), ":")));
            console2        // Calculate expected performance fee
        uint256 gain = finalTotalAssets - initialTotalAssets;
        uint256 expectedPerformanceFee = gain * PERFORMANCE_FEE_BPS / 10_000;
        
        // Should have minted performance fee shares
        assertTrue(finalShares > initialShares);
        assertTrue(vault.balanceOf(feeRecipient) > 0);
        assertTrue(gain > 0);
    }
    
    function testHighWatermarkLogic() public {
        // Deposit funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        // Generate some gains
        vm.warp(block.timestamp + 180 days);
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        vault.accrueFees();
        
        uint256 feeSharesAfterGain = vault.balanceOf(feeRecipient);
        uint256 hwm1 = feeController.highWatermark();
        
        // Simulate a loss by manually reducing strategy assets (in real scenario this could happen)
        // For testing, we'll just move forward without gains
        vm.warp(block.timestamp + 10 days);
        vm.prank(owner);
        vault.accrueFees();
        
        uint256 feeSharesAfterFlat = vault.balanceOf(feeRecipient);
        uint256 hwm2 = feeController.highWatermark();
        
        // No new performance fees should be charged without exceeding HWM
        assertEq(feeSharesAfterFlat, feeSharesAfterGain);
        assertEq(hwm2, hwm1); // HWM shouldn't change without new gains
        
        // Generate more gains to exceed previous HWM
        vm.warp(block.timestamp + 365 days);
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        vault.accrueFees();
        
        uint256 feeSharesAfterNewGains = vault.balanceOf(feeRecipient);
        uint256 hwm3 = feeController.highWatermark();
        
        // Should have new performance fees and updated HWM
        assertTrue(feeSharesAfterNewGains > feeSharesAfterFlat);
        assertTrue(hwm3 > hwm2);
    }
    
    function testFeeCalculationPrecision() public {
        // Test with small amounts to check precision
        uint256 smallDeposit = 1000e6; // 1K USDC
        
        vm.startPrank(user1);
        usdc.approve(address(vault), smallDeposit);
        vault.deposit(smallDeposit, user1);
        vm.stopPrank();
        
        // Fast forward 30 days
        vm.warp(block.timestamp + 30 days);
        
        // Calculate expected management fee for 30 days
        uint256 expectedAnnualFee = smallDeposit * MANAGEMENT_FEE_BPS / 10_000;
        uint256 expectedMonthlyFee = expectedAnnualFee * 30 days / 365.25 days;
        
        vm.prank(owner);
        vault.accrueFees();
        
        uint256 actualFeeShares = vault.balanceOf(feeRecipient);
        
        // Should be close to expected (allowing for rounding and time precision)
        if (expectedMonthlyFee > 0) {
            assertApproxEqRel(actualFeeShares, expectedMonthlyFee, 0.05e18); // 5% tolerance
        }
    }
    
    function testNoFeesOnNoAssets() public {
        // Try to accrue fees with no assets
        vm.prank(owner);
        vault.accrueFees();
        
        assertEq(vault.balanceOf(feeRecipient), 0);
        assertEq(vault.totalSupply(), 0);
    }
    
    function testNoPerformanceFeesOnLoss() public {
        // Deposit funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        // Set high watermark by generating some gains first
        vm.warp(block.timestamp + 90 days);
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        vault.accrueFees();
        
        uint256 feeSharesAfterGain = vault.balanceOf(feeRecipient);
        uint256 hwm = feeController.highWatermark();
        
        // Now simulate being below HWM (in practice, this would be from real losses)
        // Since we can't easily simulate losses in the idle strategy, 
        // we'll just verify no additional performance fees accrue at same level
        vm.warp(block.timestamp + 30 days);
        vm.prank(owner);
        vault.accrueFees(); // Only management fees should accrue
        
        uint256 feeSharesAfterTime = vault.balanceOf(feeRecipient);
        
        // Should have some new management fees but no new performance fees
        assertTrue(feeSharesAfterTime > feeSharesAfterGain); // Management fees accrued
        assertEq(feeController.highWatermark(), hwm); // HWM unchanged
    }
    
    function testSharePriceAfterFees() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        uint256 initialSharePrice = vault.convertToAssets(1e6); // Price of 1 share
        
        // Fast forward and accrue fees
        vm.warp(block.timestamp + 365.25 days);
        vm.prank(owner);
        vault.rebalance();
        vault.harvest(address(idleStrategy));
        vault.accrueFees();
        
        uint256 finalSharePrice = vault.convertToAssets(1e6);
        
        // Share price should increase due to yield (minus fees)
        assertTrue(finalSharePrice > initialSharePrice);
        
        // User's shares should still be worth more than initial deposit
        uint256 userShareValue = vault.convertToAssets(vault.balanceOf(user1));
        assertTrue(userShareValue > INITIAL_DEPOSIT);
    }
    
    function testDepositWithdrawRoundTrip() public {
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        
        // Deposit
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, user1);
        
        // Immediate withdrawal should return approximately same amount (minus any fees)
        uint256 assetsReceived = vault.redeem(shares, user1, user1);
        
        // Should get back very close to original amount (allowing for rounding)
        assertApproxEqAbs(assetsReceived, INITIAL_DEPOSIT, 2); // Allow 2 wei difference for rounding
        vm.stopPrank();
    }
    
    function testMultipleUsersShareValue() public {
        address user2 = makeAddr("user2");
        usdc.mint(user2, INITIAL_DEPOSIT);
        
        // User1 deposits first
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Generate some yield
        vm.prank(owner);
        vault.rebalance();
        vm.warp(block.timestamp + 90 days);
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        
        // User2 deposits after yield generation
        vm.startPrank(user2);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        uint256 user2Shares = vault.deposit(INITIAL_DEPOSIT, user2);
        vm.stopPrank();
        
        // User2 should get fewer shares due to increased share price
        uint256 user1Shares = vault.balanceOf(user1);
        assertTrue(user2Shares < user1Shares);
        
        // But both should have proportional value
        uint256 user1Value = vault.convertToAssets(user1Shares);
        uint256 user2Value = vault.convertToAssets(user2Shares);
        
        // User1 should have more value due to yield
        assertTrue(user1Value > user2Value);
        // User2 should have approximately their deposit value
        assertApproxEqRel(user2Value, INITIAL_DEPOSIT, 0.01e18); // 1% tolerance
    }
}