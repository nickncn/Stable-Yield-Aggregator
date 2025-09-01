// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {FeeController} from "../src/vault/FeeController.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract AccountingTest is Test {
    StableYieldVault public vault;
    FeeController public feeController;
    IdleStrategy public idleStrategy;
    MockUSDC public usdc;
    
    address public owner = makeAddr("owner");
    address public user1 = makeAddr("user1");
    address public feeRecipient = makeAddr("feeRecipient");
    
    uint256 public constant INITIAL_DEPOSIT = 100_000e6; // 100K USDC
    uint256 public constant MANAGEMENT_FEE_BPS = 100; // 1%
    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10%
    
    function setUp() public {
        usdc = new MockUSDC();
        
        vm.prank(owner);
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Test Vault",
            "TV",
            owner,
            feeRecipient,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS
        );
        
        feeController = vault.feeController();
        
        // Add idle strategy for testing
        vm.startPrank(owner);
        idleStrategy = new IdleStrategy(
            IERC20(address(usdc)),
            address(vault),
            1_000_000e6,
            500 // 5% annual rate
        );
        
        vault.addStrategy(address(idleStrategy), 10000, 1_000_000e6); // 100% weight
        vm.stopPrank();
        
        // Fund user
        usdc.mint(user1, 1_000_000e6);
    }
    
    function testManagementFeeAccrual() public {
        // Deposit funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        uint256 initialShares = vault.totalSupply();
        
        // Fast forward 1 year
        vm.warp(block.timestamp + 365.25 days);
        
        // Accrue fees
        vm.prank(owner);
        vault.accrueFees();
        
        // Check management fee was charged
        uint256 finalShares = vault.totalSupply();
        uint256 feeShares = finalShares - initialShares;
        
        // Should be approximately 1% of total assets as fee shares
        uint256 expectedFeeShares = INITIAL_DEPOSIT * MANAGEMENT_FEE_BPS / 10_000;
        assertApproxEqRel(feeShares, expectedFeeShares, 0.02e18); // 2% tolerance
        
        // Fee recipient should own the fee shares
        assertEq(vault.balanceOf(feeRecipient), feeShares);
    }
    
    function testPerformanceFeeOnGains() public {
        // Deposit funds
        vm.startPrank(user1);
        usdc.approve(address(vault), INITIAL_DEPOSIT);
        vault.deposit(INITIAL_DEPOSIT, user1);
        vm.stopPrank();
        
        // Rebalance to put funds in idle strategy
        vm.prank(owner);
        vault.rebalance();
        
        uint256 initialShares = vault.totalSupply();
        uint256 initialTotalAssets = vault.totalAssets();
        
        // Fast forward 1 year to generate yield
        vm.warp(block.timestamp + 365.25 days);
        
        // Harvest to realize gains
        vm.prank(owner);
        vault.harvest(address(idleStrategy));
        
        // Accrue performance fees
        vault.accrueFees();
        
        uint256 finalShares = vault.totalSupply();
        uint256 finalTotalAssets = vault.totalAssets();
        
        // Calculate expected performance fee
        uint256 gain = finalTotalAssets - initialTotalAssets;
        uint256 expectedPerformanceFee# file: test/mocks/MockAaveV3.sol
```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IAaveV3Pool, IAToken} from "../../src/interfaces/IAaveV3.sol";
import {SafeTransferLib} from "../../src/lib/SafeTransferLib.sol";

/**
 * @title MockAaveV3Pool & MockAToken
 * @notice Mock Aave V3 contracts for testing
 */
contract MockAaveV3Pool is IAaveV3Pool {
    using SafeTransferLib for IERC20;

    mapping(address => address) public aTokens;
    mapping(address => uint256) public liquidityRates;

    function setAToken(address asset, address aToken) external {
        aTokens[asset] = aToken;
        liquidityRates[asset] = 300; // 3% default rate
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external override {
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        MockAToken(aTokens[asset]).mint(onBehalfOf, amount);
    }

    function withdraw(address asset, uint256 amount, address to) external override returns (uint256) {
        MockAToken(aTokens[asset]).burn(msg.sender, amount);
        IERC20(asset).safeTransfer(to, amount);
        return amount;
    }

    function getReserveData(address asset) external view override returns (ReserveData memory) {
        return ReserveData({
            configuration: 0,
            liquidityIndex: 1e27,
            variableBorrowIndex: 1e27,
            currentLiquidityRate: uint128(liquidityRates[asset]),
            currentVariableBorrowRate: uint128(liquidityRates[asset] + 200),
            currentStableBorrowRate: uint128(liquidityRates[asset] + 300),
            lastUpdateTimestamp: uint40(block.timestamp),
            aTokenAddress: aTokens[asset],
            stableDebtTokenAddress: address(0),
            variableDebtTokenAddress: address(0),
            interestRateStrategyAddress: address(0),
            id: 1
        });
    }
}

contract MockAToken is IAToken {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    address public immutable POOL;
    address public immutable UNDERLYING_ASSET_ADDRESS;
    
    constructor(address _underlying, address _pool, string memory _name, string memory _symbol) {
        UNDERLYING_ASSET_ADDRESS = _underlying;
        POOL = _pool;
        name = _name;
        symbol = _symbol;
        decimals = IERC20(_underlying).decimals();
    }
    
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
    
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    function mint(address to, uint256 amount) external {
        require(msg.sender == POOL, "MockAToken: only pool");
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        require(msg.sender == POOL, "MockAToken: only pool");
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    function scaledBalanceOf(address user) external view returns (uint256) {
        return balanceOf[user];
    }

    function getScaledUserBalanceAndSupply(address user) external view returns (uint256, uint256) {
        return (balanceOf[user], totalSupply);
    }
}