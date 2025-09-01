// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StableYieldVault} from "../src/vault/StableYieldVault.sol";
import {AaveV3Strategy} from "../src/strategies/AaveV3Strategy.sol";
import {CompoundV3Strategy} from "../src/strategies/CompoundV3Strategy.sol";
import {IdleStrategy} from "../src/strategies/IdleStrategy.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {MockAaveV3Pool, MockAToken} from "../test/mocks/MockAaveV3.sol";
import {MockComet} from "../test/mocks/MockComet.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/**
 * @title Deploy Script
 * @notice Deploys the complete Stable Yield Aggregator system
 * @dev For local testing, deploys mocks. For mainnet, would use real protocol addresses
 */
contract DeployScript is Script {
    // Deployment addresses will be stored here
    StableYieldVault public vault;
    AaveV3Strategy public aaveStrategy;
    CompoundV3Strategy public compoundStrategy;
    IdleStrategy public idleStrategy;

    // Mock contracts (for local testing)
    MockUSDC public usdc;
    MockAaveV3Pool public aavePool;
    MockAToken public aToken;
    MockComet public comet;

    // Configuration
    address public owner;
    address public feeRecipient;
    uint256 public constant MANAGEMENT_FEE_BPS = 100; // 1% annual
    uint256 public constant PERFORMANCE_FEE_BPS = 1000; // 10% on gains

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.addr(deployerPrivateKey);
        feeRecipient = vm.envOr("FEE_RECIPIENT", owner);

        vm.startBroadcast(deployerPrivateKey);

        console2.log("=== Stable Yield Aggregator Deployment ===");
        console2.log("Deployer:", msg.sender);
        console2.log("Owner:", owner);
        console2.log("Fee Recipient:", feeRecipient);
        console2.log("");

        if (block.chainid == 31337 || block.chainid == 1337) {
            // Local deployment with mocks
            deployLocal();
        } else {
            // Mainnet/testnet deployment with real protocols
            deployMainnet();
        }

        // Setup strategies and initial configuration
        setupStrategies();

        // Print deployment summary
        printDeploymentSummary();

        vm.stopBroadcast();
    }

    function deployLocal() internal {
        console2.log("Deploying to local network with mocks...");

        // Deploy mock USDC
        usdc = new MockUSDC();
        console2.log("Mock USDC deployed at:", address(usdc));

        // Deploy mock Aave V3
        aavePool = new MockAaveV3Pool();
        aToken = new MockAToken(
            address(usdc),
            address(aavePool),
            "Aave USDC",
            "aUSDC"
        );
        aavePool.setAToken(address(usdc), address(aToken));
        console2.log("Mock Aave V3 Pool:", address(aavePool));
        console2.log("Mock aUSDC:", address(aToken));

        // Deploy mock Compound V3
        comet = new MockComet(address(usdc));
        console2.log("Mock Compound V3:", address(comet));

        // Fund mock protocols for testing
        usdc.mint(address(aavePool), 10_000_000e6);
        usdc.mint(address(comet), 10_000_000e6);
        usdc.mint(owner, 1_000_000e6); // Give owner some USDC for testing

        console2.log("");

        // Deploy vault
        vault = new StableYieldVault(
            IERC20(address(usdc)),
            "Stable Yield Vault",
            "SYV",
            owner,
            feeRecipient,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS
        );
        console2.log("Vault deployed at:", address(vault));
    }

    function deployMainnet() internal {
        console2.log("Deploying to mainnet/testnet...");

        // Mainnet USDC address
        address usdcAddress = getUSDCAddress();
        console2.log("Using USDC at:", usdcAddress);

        // Deploy vault
        vault = new StableYieldVault(
            IERC20(usdcAddress),
            "Stable Yield Vault",
            "SYV",
            owner,
            feeRecipient,
            MANAGEMENT_FEE_BPS,
            PERFORMANCE_FEE_BPS
        );
        console2.log("Vault deployed at:", address(vault));

        // Note: For mainnet deployment, you would use real protocol addresses
        // This is left as a placeholder for production deployment
        revert(
            "Mainnet deployment not implemented - add real protocol addresses"
        );
    }

    function setupStrategies() internal {
        console2.log("Setting up strategies...");

        if (block.chainid == 31337 || block.chainid == 1337) {
            // Local deployment with mocks

            // Deploy Aave V3 Strategy
            aaveStrategy = new AaveV3Strategy(
                vault.asset(),
                address(vault),
                500_000e6, // 500K USDC cap
                aavePool,
                aToken
            );
            console2.log("Aave V3 Strategy:", address(aaveStrategy));

            // Deploy Compound V3 Strategy
            compoundStrategy = new CompoundV3Strategy(
                vault.asset(),
                address(vault),
                500_000e6, // 500K USDC cap
                comet
            );
            console2.log("Compound V3 Strategy:", address(compoundStrategy));

            // Deploy Idle Strategy
            idleStrategy = new IdleStrategy(
                vault.asset(),
                address(vault),
                200_000e6, // 200K USDC cap
                400 // 4% annual rate
            );
            console2.log("Idle Strategy:", address(idleStrategy));

            // Add strategies to vault with target weights
            vault.addStrategy(address(aaveStrategy), 4000, 500_000e6); // 40% weight
            vault.addStrategy(address(compoundStrategy), 4000, 500_000e6); // 40% weight
            vault.addStrategy(address(idleStrategy), 2000, 200_000e6); // 20% weight

            console2.log(
                "Strategies added to vault with weights: 40% Aave, 40% Compound, 20% Idle"
            );
        }
    }

    function printDeploymentSummary() internal view {
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Vault:", address(vault));
        console2.log("Access Controller:", address(vault.accessController()));
        console2.log("Fee Controller:", address(vault.feeController()));
        console2.log("Rebalancer:", address(vault.rebalancer()));

        if (address(aaveStrategy) != address(0)) {
            console2.log("Aave V3 Strategy:", address(aaveStrategy));
        }
        if (address(compoundStrategy) != address(0)) {
            console2.log("Compound V3 Strategy:", address(compoundStrategy));
        }
        if (address(idleStrategy) != address(0)) {
            console2.log("Idle Strategy:", address(idleStrategy));
        }

        console2.log("");
        console2.log("Configuration:");
        console2.log(
            "- Management Fee:",
            MANAGEMENT_FEE_BPS,
            "bps (",
            MANAGEMENT_FEE_BPS / 100,
            "%)"
        );
        console2.log(
            "- Performance Fee:",
            PERFORMANCE_FEE_BPS,
            "bps (",
            PERFORMANCE_FEE_BPS / 100,
            "%)"
        );
        console2.log("- Owner:", owner);
        console2.log("- Fee Recipient:", feeRecipient);

        if (block.chainid == 31337 || block.chainid == 1337) {
            console2.log("");
            console2.log("=== Local Testing Setup ===");
            console2.log("Mock USDC:", address(usdc));
            console2.log("Mock Aave Pool:", address(aavePool));
            console2.log("Mock aUSDC:", address(aToken));
            console2.log("Mock Compound:", address(comet));
            console2.log("");
            console2.log("Owner USDC balance:", usdc.balanceOf(owner));
            console2.log("");
            console2.log("Next steps:");
            console2.log(
                "1. Run 'forge script script/Rebalance.s.sol' to test rebalancing"
            );
            console2.log(
                "2. Run 'forge script script/SimulatePnL.s.sol' to simulate yield"
            );
        }
    }

    function getUSDCAddress() internal view returns (address) {
        if (block.chainid == 1) {
            return 0xA0b86a33E6417c5b2C1c00b1A3B35a0d8C3c8c5d; // Mainnet USDC
        } else if (block.chainid == 11155111) {
            return 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238; // Sepolia USDC
        } else {
            revert("Unknown network for USDC address");
        }
    }
}
