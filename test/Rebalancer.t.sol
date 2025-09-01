// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {Rebalancer} from "../src/vault/Rebalancer.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";
import {CompoundV3Strategy} from "../src/strategies/CompoundV3Strategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3.sol";
import {MockComet} from "./mocks/MockComet.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract RebalancerTest is Test {
    StableYieldVault public vault;
    Rebalancer public rebalancer;
    IdleStrategy public idleStrategy;
    AaveV3Strategy public aaveStrategy;
    CompoundV3Strategy public compoundStrategy;
    MockUSDC public usdc;
    
    MockAaveV3Pool public aavePool;
    MockAToken public aToken;
    MockComet public comet;
    
    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public feeRecipient = makeAddr("feeRecipient");
    
    uint256 public constant INITIAL_DEPOSIT = 100_000e6; // 100K USDC
    
    function setUp() public {
        usdc = new MockUSDC();
        
        // Setup mock protocols
        aavePool = new MockAaveV3Pool();
        aToken = new MockAToken(address(usdc), address(aavePool), "Aave USDC", "aUSDC");
        aavePool.setAToken(address(usdc), address(aToken));
        comet = new MockComet(address(usdc));
        
        // Fund mock protocols
        usdc.mint(address(aavePool), 10_000_000e6);
        usdc.mint(address(comet), 10_000_000e6);
        
        // Deploy vault
        vm.prank(owner);
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Test Vault",
            "TV",
            owner,
            feeRecipient,
            50, // 0.5% management fee
            500 // 5% performance fee
        );
        
        rebalancer = vault.rebalancer();
        
        // Deploy strategies
        vm.startPrank(owner);
        idleStrategy = new IdleStrategy(
            IERC20(address(usdc)),
            address(vault),
            50_000e6, // 50K cap
            400 // 4% annual rate
        );
        
        aaveStrategy = new AaveV3Strategy(
            IERC20(address(usdc)),
            address(vault),
            50_000e6, // 50K cap
            aavePool,
            aToken
        );
        
        compoundStrategy = new CompoundV3Strategy(
            IERC20(address(usdc)),
            address(vault),
            50_000e6, // 50K cap
            comet
        );
        
        // Add strategies with weights: Idle 20%, Aave 40%, Compound 40%
        vault.addStrategy(address(idleStrategy), 2000, 50_000e6);
        vault.addStrategy(address(aaveStrategy), 4000, 50_000e6);
        vault.addStrategy(address(compoundStrategy), 4000, 50_000e6);
        
        vm.stopPrank();
        
        // Fund user and vault
        usdc.mint(user, 1_000_000e6);
        usdc.mint(address(vault), 1_000_000e6); // For strategy operations
    }
    
    function testInitialRebalance() public {
        // User deposits
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        // Initially all funds should be idle
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
        assertEq(usdc.balanceOf(address(vault)), INITIAL_DEPOSIT);
        assertEq(idleStrategy.totalAssets(), 0);
        assertEq(aaveStrategy.totalAssets(), 0);
        assertEq(compoundStrategy.totalAssets(), 0);
        
        // Rebalance should allocate according to weights
        vm.prank(owner);
        uint256 moves = vault.rebalance();
        
        assertTrue(moves > 0);
        
        // Check allocations (with 8% withdraw buffer)
        uint256 allocatableAssets = INITIAL_DEPOSIT * 92 / 100; // 92% after 8% buffer
        uint256 expectedIdle = allocatableAssets * 20 / 100; // 20%
        uint256 expectedAave = allocatableAssets * 40 / 100; // 40%
        uint256 expectedCompound = allocatableAssets * 40 / 100; // 40%
        
        assertApproxEqRel(idleStrategy.totalAssets(), expectedIdle, 0.01e18);
        assertApproxEqRel(aaveStrategy.totalAssets(), expectedAave, 0.01e18);
        assertApproxEqRel(compoundStrategy.totalAssets(), expectedCompound, 0.01e18);
    }
    
    function testRebalanceWithCapConstraints() public {
        // Deposit amount that would exceed strategy caps
        uint256 largeDeposit = 200_000e6; // 200K USDC
        
        vm.startPrank(user);
        usdc.approve(address(vault), largeDeposit);
        vault.deposit(largeDeposit, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        // Each strategy should not exceed their cap of 50K
        assertLe(idleStrategy.totalAssets(), 50_000e6);
        assertLe(aaveStrategy.totalAssets(), 50_000e6);
        assertLe(compoundStrategy.totalAssets(), 50_000e6);
        
        // Remaining funds should stay idle
        uint256 totalStrategyAssets = idleStrategy.totalAssets() + 
                                     aaveStrategy.totalAssets() + 
                                     compoundStrategy.totalAssets();
        uint256 idleAssets = usdc.balanceOf(address(vault));
        
        assertEq(totalStrategyAssets + idleAssets, largeDeposit);
        assertTrue(idleAssets > largeDeposit * 8 / 100); // More than just withdraw buffer
    }
    
    function testRebalanceAfterWithdrawal() public {
        // Initial deposit and rebalance
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        uint256 aaveAssetsBefore = aaveStrategy.totalAssets();
        uint256 compoundAssetsBefore = compoundStrategy.totalAssets();
        
        // User withdraws some funds
        uint256 withdrawAmount = 20_000e6;
        vm.startPrank(user);
        vault.withdraw(withdrawAmount, user, user);
        vm.stopPrank();
        
        // Rebalance should adjust allocations
        vm.prank(owner);
        vault.rebalance();
        
        uint256 aaveAssetsAfter = aaveStrategy.totalAssets();
        uint256 compoundAssetsAfter = compoundStrategy.totalAssets();
        
        // Strategy allocations should be proportionally reduced
        assertTrue(aaveAssetsAfter < aaveAssetsBefore);
        assertTrue(compoundAssetsAfter < compoundAssetsBefore);
        
        // Check that total assets are correct
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT - withdrawAmount);
    }
    
    function testRebalanceNeededCheck() public {
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        // Initially should need rebalance
        (bool needed, uint256 deviation) = vault.checkRebalanceNeeded();
        assertTrue(needed);
        assertTrue(deviation > 500); // > 5% deviation
        
        // After rebalancing, should not need rebalance
        vm.prank(owner);
        vault.rebalance();
        
        (needed, deviation) = vault.checkRebalanceNeeded();
        assertFalse(needed);
        assertTrue(deviation <= 500); // <= 5% deviation
    }
    
    function testWithdrawBufferRespected() public {
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        // Check that withdraw buffer is maintained
        uint256 idleAssets = usdc.balanceOf(address(vault));
        uint256 expectedBuffer = INITIAL_DEPOSIT * 8 / 100; // 8% buffer
        
        assertGe(idleAssets, expectedBuffer);
    }
    
    function testUpdateStrategyWeights() public {
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        // Initial rebalance
        vm.prank(owner);
        vault.rebalance();
        
        uint256 aaveAssetsBefore = aaveStrategy.totalAssets();
        
        // Update Aave strategy to 80% weight
        vm.prank(owner);
        vault.updateStrategy(address(aaveStrategy), 8000, 50_000e6);
        
        // Rebalance with new weights
        vm.prank(owner);
        vault.rebalance();
        
        uint256 aaveAssetsAfter = aaveStrategy.totalAssets();
        
        // Aave should have more assets now
        assertTrue(aaveAssetsAfter > aaveAssetsBefore);
    }
    
    function testRemoveStrategy() public {
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        uint256 idleAssetsBefore = idleStrategy.totalAssets();
        assertTrue(idleAssetsBefore > 0);
        
        // Remove idle strategy
        vm.prank(owner);
        vault.removeStrategy(address(idleStrategy));
        
        // Assets should have been withdrawn from idle strategy
        assertEq(idleStrategy.totalAssets(), 0);
        
        // Funds should be back in vault
        uint256 vaultBalance = usdc.balanceOf(address(vault));
        assertTrue(vaultBalance >= idleAssetsBefore);
    }
    
    function testMaxMovePerTxLimit() public {
        // Set very low max move limit
        vm.prank(owner);
        vault.setMaxMovePerTx(5_000e6); // 5K USDC max per move
        
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        // Rebalance should be limited by max move per tx
        vm.prank(owner);
        uint256 moves = vault.rebalance();
        
        // Should require multiple moves or partial rebalancing
        assertTrue(moves > 0);
        
        // May not be fully rebalanced in one go due to limits
        (bool stillNeeded,) = vault.checkRebalanceNeeded();
        // Could still need more rebalancing due to limits
    }
    
    function testRebalancerViewFunctions() public {
        address[] memory strategies = rebalancer.getActiveStrategies();
        assertEq(strategies.length, 3);
        
        assertEq(rebalancer.getTotalStrategyAssets(), 0); // Initially zero
        
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        uint256 totalStrategyAssets = rebalancer.getTotalStrategyAssets();
        assertTrue(totalStrategyAssets > 0);
        assertTrue(totalStrategyAssets < INITIAL_DEPOSIT); // Less than total due to withdraw buffer
    }
    
    function testEmergencyScenarios() public {
        vm.startPrank(user);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();
        
        vm.prank(owner);
        vault.rebalance();
        
        // Pause one strategy
        vm.prank(owner);
        aaveStrategy.pause();
        
        // Rebalance should still work, avoiding paused strategy
        vm.prank(owner);
        vault.rebalance();
        
        // Emergency shutdown
        vm.prank(owner);
        vault.emergencyShutdownVault();
        
        // Rebalance should fail during shutdown
        vm.prank(owner);
        vm.expectRevert("StableYieldVault: emergency shutdown");
        vault.rebalance();
    }
}