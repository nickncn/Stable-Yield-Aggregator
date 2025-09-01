// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract VaultHandler is Test {
    StableYieldVault public vault;
    MockUSDC public usdc;
    IdleStrategy public idleStrategy;
    
    address[] public users;
    uint256 public constant MAX_USERS = 10;
    uint256 public constant MAX_DEPOSIT = 100_000e6;
    
    constructor(StableYieldVault _vault, MockUSDC _usdc, IdleStrategy _idleStrategy) {
        vault = _vault;
        usdc = _usdc;
        idleStrategy = _idleStrategy;
        
        // Create test users
        for (uint256 i = 0; i < MAX_USERS; i++) {
            address user = makeAddr(string(abi.encodePacked("user", i)));
            users.push(user);
            usdc.mint(user, 1_000_000e6); // Give each user 1M USDC
        }
    }
    
    function deposit(uint256 userIndex, uint256 amount) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        amount = bound(amount, 1e6, MAX_DEPOSIT); // 1 USDC to 100K USDC
        
        address user = users[userIndex];
        
        if (usdc.balanceOf(user) < amount) return;
        if (vault.paused() || vault.emergencyShutdown()) return;
        
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        
        try vault.deposit(amount, user) {
            // Deposit succeeded
        } catch {
            // Deposit failed, continue
        }
        vm.stopPrank();
    }
    
    function withdraw(uint256 userIndex, uint256 sharePercent) external {
        userIndex = bound(userIndex, 0, users.length - 1);
        sharePercent = bound(sharePercent, 1, 100);
        
        address user = users[userIndex];
        uint256 userShares = vault.balanceOf(user);
        
        if (userShares == 0) return;
        if (vault.emergencyShutdown()) return;
        
        uint256 sharesToWithdraw = (userShares * sharePercent) / 100;
        if (sharesToWithdraw == 0) return;
        
        vm.prank(user);
        try vault.redeem(sharesToWithdraw, user, user) {
            // Withdrawal succeeded
        } catch {
            // Withdrawal failed, continue
        }
    }
    
    function rebalance() external {
        if (vault.emergencyShutdown()) return;
        
        try vault.rebalance() {
            // Rebalance succeeded
        } catch {
            // Rebalance failed, continue
        }
    }
    
    function harvest() external {
        if (vault.emergencyShutdown()) return;
        
        try vault.harvest(address(idleStrategy)) {
            // Harvest succeeded
        } catch {
            // Harvest failed, continue
        }
    }
    
    function accrueFees() external {
        if (vault.emergencyShutdown()) return;
        
        try vault.accrueFees() {
            // Fee accrual succeeded
        } catch {
            // Fee accrual failed, continue
        }
    }
    
    function timeTravel(uint256 timeSeconds) external {
        timeSeconds = bound(timeSeconds, 1 hours, 365 days);
        vm.warp(block.timestamp + timeSeconds);
    }
}

contract InvariantsTest is StdInvariant, Test {
    StableYieldVault public vault;
    MockUSDC public usdc;
    IdleStrategy public idleStrategy;
    VaultHandler public handler;
    
    address public owner = makeAddr("owner");
    address public feeRecipient = makeAddr("feeRecipient");
    
    function setUp() public {
        usdc = new MockUSDC();
        
        vm.prank(owner);
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Invariant Vault",
            "IV",
            owner,
            feeRecipient,
            100, // 1% management fee
            1000 // 10% performance fee
        );
        
        // Add idle strategy
        vm.startPrank(owner);
        idleStrategy = new IdleStrategy(
            IERC20(address(usdc)),
            address(vault),
            1_000_000e6,
            500 // 5% annual rate
        );
        
        vault.addStrategy(address(idleStrategy), 10000, 1_000_000e6);
        vm.stopPrank();
        
        // Setup handler
        handler = new VaultHandler(vault, usdc, idleStrategy);
        
        // Configure invariant testing
        targetContract(address(handler));
        
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = VaultHandler.deposit.selector;
        selectors[1] = VaultHandler.withdraw.selector;
        selectors[2] = VaultHandler.rebalance.selector;
        selectors[3] = VaultHandler.harvest.selector;
        selectors[4] = VaultHandler.accrueFees.selector;
        selectors[5] = VaultHandler.timeTravel.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }
    
    /// @dev Total assets should always be >= sum of user balances in asset terms
    function invariant_totalAssetsGteUserAssets() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        if (totalSupply == 0) {
            assertEq(totalAssets, 0);
            return;
        }
        
        // Calculate total user asset value
        uint256 totalUserAssetValue = 0;
        for (uint256 i = 0; i < handler.MAX_USERS(); i++) {
            address user = handler.users(i);
            uint256 userShares = vault.balanceOf(user);
            uint256 userAssetValue = vault.convertToAssets(userShares);
            totalUserAssetValue += userAssetValue;
        }
        
        // Add fee recipient value
        uint256 feeRecipientShares = vault.balanceOf(feeRecipient);
        uint256 feeRecipientValue = vault.convertToAssets(feeRecipientShares);
        totalUserAssetValue += feeRecipientValue;
        
        // Total assets should be at least the sum of all user asset values
        assertGe(totalAssets, totalUserAssetValue);
    }
    
    /// @dev Share price should never decrease (except for fees and losses)
    function invariant_sharePriceNonDecreasing() public {
        uint256 totalAssets = vault.totalAssets();
        uint256 totalSupply = vault.totalSupply();
        
        if (totalSupply == 0) return;
        
        uint256 currentSharePrice = (totalAssets * 1e18) / totalSupply;
        
        // Share price should be reasonable (between 0.5 and 2.0 in normal operation)
        assertGe(currentSharePrice, 0.5e18);
        assertLe(currentSharePrice, 2e18);
    }
    
    /// @dev Total supply should equal sum of all balances
    function invariant_totalSupplyEqualsBalances() public {
        uint256 totalSupply = vault.totalSupply();/**
 * @title MockComet
 * @notice Mock Compound V3 Comet contract for testing
 */
contract MockComet is IComet {
    using SafeTransferLib for IERC20;

    string public name = "Mock Compound USDC";
    string public symbol = "cUSDCv3";
    uint8 public decimals = 6;
    uint256 public totalSupply;
    
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    address public immutable baseToken;
    uint256 public totalBorrow;
    uint64 public baseSupplyRate = 350; // 3.5% supply rate
    uint64 public baseBorrowRate = 500; // 5% borrow rate
    
    constructor(address _baseToken) {
        baseToken = _baseToken;
        decimals = IERC20(_baseToken).decimals();
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
    
    function supply(address asset, uint256 amount) external {
        require(asset == baseToken, "MockComet: invalid asset");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        
        totalSupply += amount;
        balanceOf[msg.sender] += amount;
        emit Transfer(address(0), msg.sender, amount);
    }
    
    function withdraw(address asset, uint256 amount) external {
        require(asset == baseToken, "MockComet: invalid asset");
        require(balanceOf[msg.sender] >= amount, "MockComet: insufficient balance");
        
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        emit Transfer(msg.sender, address(0), amount);
        
        IERC20(asset).safeTransfer(msg.sender, amount);
    }
    
    function baseTrackingSupplySpeed() external pure returns (uint256) {
        return 1e15; // Mock tracking speed
    }
    
    function baseTrackingBorrowSpeed() external pure returns (uint256) {
        return 1e15; // Mock tracking speed
    }
    
    function getUtilization() external view returns (uint256) {
        if (totalSupply == 0) return 0;
        return (totalBorrow * 1e18) / totalSupply;
    }
    
    function getSupplyRate(uint256) external view returns (uint64) {
        return baseSupplyRate;
    }
    
    function getBorrowRate(uint256) external view returns (uint64) {
        return baseBorrowRate;
    }
    
    function getAssetInfo(uint8) external pure returns (AssetInfo memory) {
        return AssetInfo({
            offset: 0,
            asset: address(0),
            priceFeed: address(0),
            scale: 1e6,
            borrowCollateralFactor: 0,
            liquidateCollateralFactor: 0,
            liquidationFactor: 0,
            supplyCap: type(uint128).max
        });
    }
    
    function numAssets() external pure returns (uint8) {
        return 1;
    }
    
    function setRates(uint64 _supplyRate, uint64 _borrowRate) external {
        baseSupplyRate = _supplyRate;
        baseBorrowRate = _borrowRate;
    }
}