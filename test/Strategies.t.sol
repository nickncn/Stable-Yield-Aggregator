// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";
import {CompoundV3Strategy} from "../src/strategies/CompoundV3Strategy.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {MockAaveV3Pool, MockAToken} from "./mocks/MockAaveV3.sol";
import {MockComet} from "./mocks/MockComet.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract StrategiesTest is Test {
    MockUSDC public usdc;
    AaveV3Strategy public aaveStrategy;
    CompoundV3Strategy public compoundStrategy;
    IdleStrategy public idleStrategy;
    
    MockAaveV3Pool public aavePool;
    MockAToken public aToken;
    MockComet public comet;
    
    address public vault = makeAddr("vault");
    address public user = makeAddr("user");
    
    uint256 public constant MAX_CAP = 1_000_000e6; // 1M USDC cap
    uint256 public constant DEPOSIT_AMOUNT = 10_000e6; // 10K USDC
    
    function setUp() public {
        // Deploy mock USDC
        usdc = new MockUSDC();
        
        // Setup Aave V3 mocks
        aavePool = new MockAaveV3Pool();
        aToken = new MockAToken(address(usdc), address(aavePool), "Aave USDC", "aUSDC");
        aavePool.setAToken(address(usdc), address(aToken));
        
        // Setup Compound V3 mocks
        comet = new MockComet(address(usdc));
        
        // Deploy strategies
        vm.startPrank(vault);
        aaveStrategy = new AaveV3Strategy(
            IERC20(address(usdc)),
            vault,
            MAX_CAP,
            aavePool,
            aToken
        );
        
        compoundStrategy = new CompoundV3Strategy(
            IERC20(address(usdc)),
            vault,
            MAX_CAP,
            comet
        );
        
        idleStrategy = new IdleStrategy(
            IERC20(address(usdc)),
            vault,
            MAX_CAP,
            400 // 4% annual rate
        );
        vm.stopPrank();
        
        // Fund vault with USDC for strategy operations
        usdc.mint(vault, 1_000_000e6);
        
        // Fund mock protocols
        usdc.mint(address(aavePool), 1_000_000e6);
        usdc.mint(address(comet), 1_000_000e6);
    }
    
    function testAaveStrategyDeposit() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        
        uint256 shares = aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(aaveStrategy.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(aToken.balanceOf(address(aaveStrategy)), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }
    
    function testAaveStrategyWithdraw() public {
        // First deposit
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Then withdraw
        uint256 withdrawAmount = 5_000e6;
        uint256 shares = aaveStrategy.withdraw(withdrawAmount);
        
        assertEq(shares, withdrawAmount);
        assertEq(aaveStrategy.totalAssets(), DEPOSIT_AMOUNT - withdrawAmount);
        assertEq(usdc.balanceOf(vault), 1_000_000e6 - DEPOSIT_AMOUNT + withdrawAmount);
        vm.stopPrank();
    }
    
    function testCompoundStrategyDeposit() public {
        vm.startPrank(vault);
        usdc.approve(address(compoundStrategy), DEPOSIT_AMOUNT);
        
        uint256 shares = compoundStrategy.deposit(DEPOSIT_AMOUNT);
        
        assertEq(shares, DEPOSIT_AMOUNT);
        assertEq(compoundStrategy.totalAssets(), DEPOSIT_AMOUNT);
        assertEq(comet.balanceOf(address(compoundStrategy)), DEPOSIT_AMOUNT);
        vm.stopPrank();
    }
    
    function testCompoundStrategyWithdraw() public {
        // First deposit
        vm.startPrank(vault);
        usdc.approve(address(compoundStrategy), DEPOSIT_AMOUNT);
        compoundStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Then withdraw
        uint256 withdrawAmount = 3_000e6;
        uint256 shares = compoundStrategy.withdraw(withdrawAmount);
        
        assertEq(shares, withdrawAmount);
        assertEq(compoundStrategy.totalAssets(), DEPOSIT_AMOUNT - withdrawAmount);
        vm.stopPrank();
    }
    
    function testIdleStrategyAccrual() public {
        vm.startPrank(vault);
        usdc.approve(address(idleStrategy), DEPOSIT_AMOUNT);
        
        // Deposit
        idleStrategy.deposit(DEPOSIT_AMOUNT);
        assertEq(idleStrategy.totalAssets(), DEPOSIT_AMOUNT);
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365.25 days);
        
        // Check accrued interest (should be ~4%)
        uint256 totalAssetsAfter = idleStrategy.totalAssets();
        uint256 expectedInterest = DEPOSIT_AMOUNT * 400 / 10_000; // 4%
        assertApproxEqRel(totalAssetsAfter, DEPOSIT_AMOUNT + expectedInterest, 0.01e18); // 1% tolerance
        vm.stopPrank();
    }
    
    function testIdleStrategyWithdrawWithInterest() public {
        vm.startPrank(vault);
        usdc.approve(address(idleStrategy), DEPOSIT_AMOUNT);
        
        // Deposit
        idleStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Fast forward 6 months
        vm.warp(block.timestamp + 182.625 days);
        
        // Withdraw all (should include ~2% interest)
        uint256 totalBefore = idleStrategy.totalAssets();
        idleStrategy.withdraw(totalBefore);
        
        uint256 expectedInterest = DEPOSIT_AMOUNT * 200 / 10_000; // 2% for 6 months
        assertApproxEqRel(totalBefore, DEPOSIT_AMOUNT + expectedInterest, 0.01e18); // 1% tolerance
        vm.stopPrank();
    }
    
    function testStrategyPauseFunctionality() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        
        // Should be able to deposit initially
        aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Pause strategy
        aaveStrategy.pause();
        assertTrue(aaveStrategy.paused());
        
        // Should not be able to deposit when paused
        vm.expectRevert("BaseStrategy: paused");
        aaveStrategy.deposit(1000e6);
        
        // But should be able to withdraw
        aaveStrategy.withdraw(1000e6);
        
        // Unpause
        aaveStrategy.unpause();
        assertFalse(aaveStrategy.paused());
        
        // Should be able to deposit again
        aaveStrategy.deposit(1000e6);
        vm.stopPrank();
    }
    
    function testStrategyCaps() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), type(uint256).max);
        
        // Should be able to deposit up to cap
        assertEq(aaveStrategy.maxDeposit(vault), MAX_CAP);
        
        // Deposit almost to cap
        aaveStrategy.deposit(MAX_CAP - 1000e6);
        
        // Should only be able to deposit remaining amount
        assertEq(aaveStrategy.maxDeposit(vault), 1000e6);
        
        // Deposit remaining
        aaveStrategy.deposit(1000e6);
        
        // Should not be able to deposit more
        assertEq(aaveStrategy.maxDeposit(vault), 0);
        vm.stopPrank();
    }
    
    function testStrategyReporting() public {
        vm.startPrank(vault);
        usdc.approve(address(idleStrategy), DEPOSIT_AMOUNT);
        
        // Deposit
        idleStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Fast forward to accrue some interest
        vm.warp(block.timestamp + 90 days);
        
        // Report should show gain
        (uint256 gain, uint256 loss) = idleStrategy.report();
        
        assertTrue(gain > 0);
        assertEq(loss, 0);
        
        uint256 expectedGain = DEPOSIT_AMOUNT * 100 / 10_000; // ~1% for 3 months
        assertApproxEqRel(gain, expectedGain, 0.1e18); // 10% tolerance for timing
        vm.stopPrank();
    }
    
    function testStrategyHealthMetrics() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        (
            uint256 currentAssets,
            uint256 currentDebt,
            uint256 utilizationBps,
            uint256 timeSinceReport,
            bool isPaused
        ) = aaveStrategy.getHealthMetrics();
        
        assertEq(currentAssets, DEPOSIT_AMOUNT);
        assertEq(currentDebt, DEPOSIT_AMOUNT);
        assertEq(utilizationBps, DEPOSIT_AMOUNT * 10_000 / MAX_CAP); // Utilization based on cap
        assertEq(timeSinceReport, 0); // Just reported in constructor
        assertFalse(isPaused);
        vm.stopPrank();
    }
    
    function testEmergencyWithdraw() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Pause strategy first (required for emergency withdraw)
        aaveStrategy.pause();
        
        // Emergency withdraw should get all funds back
        uint256 withdrawn = aaveStrategy.emergencyWithdrawAll();
        assertEq(withdrawn, DEPOSIT_AMOUNT);
        assertEq(aaveStrategy.totalAssets(), 0);
        vm.stopPrank();
    }
    
    function testSlippageProtection() public {
        vm.startPrank(vault);
        usdc.approve(address(aaveStrategy), DEPOSIT_AMOUNT);
        aaveStrategy.deposit(DEPOSIT_AMOUNT);
        
        // Set very strict slippage (99.9%)
        aaveStrategy.setMinLiquidityOut(9990);
        
        // Normal withdrawal should work
        aaveStrategy.withdraw(1000e6);
        
        // TODO: Test scenario where slippage is too high - would need to mock protocol failure
        vm.stopPrank();
    }
}