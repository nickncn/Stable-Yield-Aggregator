// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract FuzzShareAccountingTest is Test {
    StableYieldVault public vault;
    MockUSDC public usdc;
    IdleStrategy public idleStrategy;
    
    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    
    function setUp() public {
        usdc = new MockUSDC();
        
        vm.prank(owner);
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Fuzz Vault",
            "FV",
            owner,
            feeRecipient,
            50, // 0.5% management fee
            500 // 5% performance fee
        );
        
        // Add idle strategy
        vm.startPrank(owner);
        idleStrategy = new IdleStrategy(
            IERC20(address(usdc)),
            address(vault),
            10_000_000e6,
            300 // 3% annual rate
        );
        
        vault.addStrategy(address(idleStrategy), 10000, 10_000_000e6);
        vm.stopPrank();
    }
    
    function testFuzzDeposit(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6); // 1 USDC to 1M USDC
        
        address user = makeAddr("fuzzUser");
        usdc.mint(user, amount);
        
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        
        uint256 sharesBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        
        uint256 shares = vault.deposit(amount, user);
        
        uint256 sharesAfter = vault.totalSupply();
        uint256 assetsAfter = vault.totalAssets();
        
        // Shares should increase by amount returned
        assertEq(sharesAfter - sharesBefore, shares);
        
        // Assets should increase by deposited amount
        assertEq(assetsAfter - assetsBefore, amount);
        
        // User should own the returned shares
        assertEq(vault.balanceOf(user), shares);
        
        // Share calculation should be consistent
        if (sharesBefore == 0) {
            assertEq(shares, amount); // 1:1 ratio for first deposit
        } else {
            uint256 expectedShares = (amount * sharesBefore) / assetsBefore;
            assertApproxEqAbs(shares, expectedShares, 1); // Allow 1 wei rounding error
        }
        
        vm.stopPrank();
    }
    
    function testFuzzWithdraw(uint256 depositAmount, uint256 withdrawPercent) public {
        depositAmount = bound(depositAmount, 1000e6, 1_000_000e6);
        withdrawPercent = bound(withdrawPercent, 1, 100);
        
        address user = makeAddr("fuzzUser");
        usdc.mint(user, depositAmount);
        
        // First deposit
        vm.startPrank(user);
        usdc.approve(address(vault), depositAmount);
        uint256 shares = vault.deposit(depositAmount, user);
        
        // Then withdraw a percentage
        uint256 sharesToWithdraw = (shares * withdrawPercent) / 100;
        
        uint256 sharesBefore = vault.totalSupply();
        uint256 assetsBefore = vault.totalAssets();
        uint256 userBalanceBefore = usdc.balanceOf(user);
        
        uint256 assetsWithdrawn = vault.redeem(sharesToWithdraw, user, user);
        
        uint256 sharesAfter = vault.totalSupply();
        uint256 assetsAfter = vault.totalAssets();
        uint256 userBalanceAfter = usdc.balanceOf(user);
        
        // Shares should decrease by redeemed amount
        assertEq(sharesBefore - sharesAfter, sharesToWithdraw);
        
        // Assets should decrease by withdrawn amount
        assertEq(assetsBefore - assetsAfter, assetsWithdrawn);
        
        // User should receive the assets
        assertEq(userBalanceAfter - userBalanceBefore, assetsWithdrawn);
        
        // User share balance should decrease
        assertEq(vault.balanceOf(user), shares - sharesToWithdraw);
        
        vm.stopPrank();
    }
    
    function testFuzzMultipleUsers(
        uint256[5] memory deposits,
        uint256[5] memory withdrawPercents,
        uint256 timeElapsed
    ) public {
        // Bound inputs
        for (uint256 i = 0; i < 5; i++) {
            deposits[i] = bound(deposits[i], 1000e6, 100_000e6);
            withdrawPercents[i] = bound(withdrawPercents[i], 0, 100);
        }
        timeElapsed = bound(timeElapsed, 1 days, 365 days);
        
        address[5] memory users = [
            makeAddr("user0"),
            makeAddr("user1"), 
            makeAddr("user2"),
            makeAddr("user3"),
            makeAddr("user4")
        ];
        
        uint256[] memory userShares = new uint256[](5);
        
        // Phase 1: All users deposit
        uint256 totalDeposited = 0;
        for (uint256 i = 0; i < 5; i++) {
            usdc.mint(users[i], deposits[i]);
            
            vm.startPrank(users[i]);
            usdc.approve(address(vault), deposits[i]);
            userShares[i] = vault.deposit(deposits[i], users[i]);
            vm.stopPrank();
            
            totalDeposited += deposits[i];
        }
        
        // Check initial state
        assertEq(vault.totalAssets(), totalDeposited);
        
        uint256 totalSharesIssued = 0;
        for (uint256 i = 0; i < 5; i++) {
            totalSharesIssued += userShares[i];
        }
        assertEq(vault.totalSupply(), totalSharesIssued);
        
        // Phase 2: Rebalance and let time pass
        vm.prank(owner);
        vault.rebalance();
        
        vm.warp(block.timestamp + timeElapsed);
        
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        
        // Phase 3: Users withdraw
        uint256 totalWithdrawn = 0;
        for (uint256 i = 0; i < 5; i++) {
            if (withdrawPercents[i] == 0) continue;
            
            uint256 sharesToWithdraw = (userShares[i] * withdrawPercents[i]) / 100;
            if (sharesToWithdraw == 0) continue;
            
            vm.prank(users[i]);
            uint256 assetsReceived = vault.redeem(sharesToWithdraw, users[i], users[i]);
            
            totalWithdrawn += assetsReceived;
            userShares[i] -= sharesToWithdraw;
        }
        
        // Invariant checks
        uint256 remainingShares = 0;
        for (uint256 i = 0; i < 5; i++) {
            assertEq(vault.balanceOf(users[i]), userShares[i]);
            remainingShares += userShares[i];
        }
        
        // Add fee recipient shares
        remainingShares += vault.balanceOf(feeRecipient);
        assertEq(vault.totalSupply(), remainingShares);
        
        // Total assets should be reasonable
        uint256 finalTotalAssets = vault.totalAssets();
        assertTrue(finalTotalAssets > 0);
        
        // Share price should be reasonable
        if (remainingShares > 0) {
            uint256 sharePrice = (finalTotalAssets * 1e18) / remainingShares;
            assertGe(sharePrice, 0.9e18); // Should not have lost more than 10%
            assertLe(sharePrice, 2e18); // Should not have more than 2x gains
        }
    }
    
    function testFuzzDepositWithdrawRoundTrip(uint256 amount, uint256 timeElapsed) public {
        amount = bound(amount, 1000e6, 100_000e6);
        timeElapsed = bound(timeElapsed, 1 hours, 30 days);
        
        address user = makeAddr("roundTripUser");
        usdc.mint(user, amount);
        
        uint256 initialBalance = usdc.balanceOf(user);
        
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        
        // Deposit
        uint256 shares = vault.deposit(amount, user);
        
        // Let some time pass
        vm.warp(block.timestamp + timeElapsed);
        
        // Withdraw all shares
        uint256 assetsReceived = vault.redeem(shares, user, user);
        
        vm.stopPrank();
        
        uint256 finalBalance = usdc.balanceOf(user);
        
        // User should have received at least their principal back (minus small rounding)
        assertGe(finalBalance, initialBalance - 2); // Allow 2 wei rounding error
        
        // Should not have received impossibly more
        assertLe(finalBalance, initialBalance * 110 / 100); // Not more than 10% gain in short time
    }
    
    function testFuzzPreviewFunctions(uint256 amount) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        
        address user = makeAddr("previewUser");
        usdc.mint(user, amount * 2);
        
        // Test preview functions with empty vault
        assertEq(vault.previewDeposit(amount), amount);
        assertEq(vault.previewMint(amount), amount);
        assertEq(vault.previewWithdraw(amount), amount);
        assertEq(vault.previewRedeem(amount), amount);
        
        // Make a deposit to change vault state
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        vault.deposit(amount, user);
        
        // Test preview functions with vault having assets
        uint256 previewShares = vault.previewDeposit(amount);
        uint256 previewAssets = vault.previewMint(amount);
        
        // Actually perform operations and compare
        usdc.approve(address(vault), amount);
        uint256 actualShares = vault.deposit(amount, user);
        
        // Preview should match actual (within rounding)
        assertApproxEqAbs(previewShares, actualShares, 1);
        
        vm.stopPrank();
    }
    
    function testFuzzShareInflationAttack(uint256 attackAmount, uint256 victimAmount) public {
        attackAmount = bound(attackAmount, 1e6, 1000e6); // Small attack
        victimAmount = bound(victimAmount, 1_000e6, 1_000_000e6); // Larger victim deposit
        
        address attacker = makeAddr("attacker");
        address victim = makeAddr("victim");
        
        usdc.mint(attacker, attackAmount * 2);
        usdc.mint(victim, victimAmount);
        
        // Attacker tries to manipulate share price by depositing small amount first
        vm.startPrank(attacker);
        usdc.approve(address(vault), attackAmount);
        uint256 attackerShares = vault.deposit(attackAmount, attacker);
        vm.stopPrank();
        
        // Victim deposits larger amount
        vm.startPrank(victim);
        usdc.approve(address(vault), victimAmount);
        uint256 victimShares = vault.deposit(victimAmount, victim);
        vm.stopPrank();
        
        // Victim should receive fair share ratio
        // Since USDC has 6 decimals, precision loss should be minimal
        uint256 expectedVictimShares = (victimAmount * attackerShares) / attackAmount;
        
        // Allow for small rounding differences
        assertApproxEqRel(victimShares, expectedVictimShares, 0.001e18); // 0.1% tolerance
        
        // Victim should be able to withdraw approximately their deposit
        vm.prank(victim);
        uint256 assetsReceived = vault.redeem(victimShares, victim, victim);
        
        // Should get back close to original amount
        assertApproxEqRel(assetsReceived, victimAmount, 0.001e18); // 0.1% tolerance
    }
}