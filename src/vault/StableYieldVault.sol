// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626Minimal} from "../lib/ERC4626Minimal.sol";
import {AccessController} from "./AccessController.sol";
import {FeeController} from "./FeeController.sol";
import {Rebalancer} from "./Rebalancer.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";
import {FixedPointMathLib} from "../lib/FixedPointMathLib.sol";

/**
 * @title StableYieldVault
 * @notice ERC-4626 vault that allocates USDC across multiple yield strategies
 * @dev Main vault contract coordinating strategies, fees, and rebalancing
 */
contract StableYieldVault is ERC4626Minimal {
    using SafeTransferLib for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Harvest(address indexed strategy, uint256 gain, uint256 loss);
    event Rebalance(uint256 totalMoves, uint256 gasUsed);
    event StrategyAdded(address indexed strategy, uint256 targetWeight, uint256 maxCap);
    event StrategyUpdated(address indexed strategy, uint256 targetWeight, uint256 maxCap);
    event EmergencyShutdown(bool shutdown);
    event VaultPaused(bool paused);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    AccessController public immutable accessController;
    FeeController public immutable feeController;
    Rebalancer public immutable rebalancer;

    bool public emergencyShutdown;
    bool public paused;
    uint256 public lastReport;
    uint256 public lastRebalance;

    // Performance tracking
    uint256 public totalGainRealized;
    uint256 public totalLossRealized;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        require(msg.sender == accessController.owner(), "StableYieldVault: not owner");
        _;
    }

    modifier onlyKeeper() {
        require(
            accessController.hasRole(accessController.KEEPER_ROLE(), msg.sender) ||
            msg.sender == accessController.owner(),
            "StableYieldVault: not keeper"
        );
        _;
    }

    modifier onlyPauser() {
        require(
            accessController.hasRole(accessController.PAUSER_ROLE(), msg.sender) ||
            msg.sender == accessController.owner(),
            "StableYieldVault: not pauser"
        );
        _;
    }

    modifier whenNotPaused() {
        require(!paused && !emergencyShutdown, "StableYieldVault: paused or shutdown");
        _;
    }

    modifier whenNotShutdown() {
        require(!emergencyShutdown, "StableYieldVault: emergency shutdown");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        IERC20 _asset,
        string memory _name,
        string memory _symbol,
        address _owner,
        address _feeRecipient,
        uint256 _managementFeeBps,
        uint256 _performanceFeeBps
    ) ERC4626Minimal(_asset, _name, _symbol) {
        accessController = new AccessController(_owner);
        feeController = new FeeController(_feeRecipient, _managementFeeBps, _performanceFeeBps);
        rebalancer = new Rebalancer(_asset);
        
        lastReport = block.timestamp;
        lastRebalance = block.timestamp;
    }

    /*//////////////////////////////////////////////////////////////
                            ERC4626 OVERRIDES
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Total assets = strategy assets + idle USDC + accrued fees
     */
    function totalAssets() public view override returns (uint256) {
        uint256 strategyAssets = rebalancer.getTotalStrategyAssets();
        uint256 idleAssets = asset.balanceOf(address(this));
        return strategyAssets + idleAssets;
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (paused || emergencyShutdown) return 0;
        return type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        if (paused || emergencyShutdown) return 0;
        return type(uint256).max;
    }

    function beforeWithdraw(uint256 assets, uint256 /*shares*/) internal override {
        // Ensure sufficient liquidity for withdrawal
        _ensureLiquidity(assets);
    }

    function afterDeposit(uint256 assets, uint256 shares) internal override {
        // Consider triggering rebalance if deposit is significant
        if (assets > totalAssets() / 20) { // > 5% of total assets
            _checkRebalanceNeeded();
        }
        
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    /*//////////////////////////////////////////////////////////////
                            DEPOSIT/WITHDRAW LOGIC  
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) 
        public 
        override 
        whenNotPaused 
        returns (uint256 shares) 
    {
        // Accrue fees before deposit to ensure fair share pricing
        _accrueFees();
        shares = super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) 
        public 
        override 
        whenNotPaused 
        returns (uint256 assets) 
    {
        // Accrue fees before mint to ensure fair share pricing
        _accrueFees();
        assets = super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        whenNotShutdown
        returns (uint256 shares)
    {
        // Accrue fees before withdrawal to ensure fair share pricing
        _accrueFees();
        shares = super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        whenNotShutdown
        returns (uint256 assets)
    {
        // Accrue fees before redemption to ensure fair share pricing
        _accrueFees();
        assets = super.redeem(shares, receiver, owner);
    }

    /*//////////////////////////////////////////////////////////////
                             STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addStrategy(
        address strategy,
        uint256 targetWeight,
        uint256 maxCap
    ) external onlyOwner {
        rebalancer.addStrategy(strategy, targetWeight, maxCap);
        emit StrategyAdded(strategy, targetWeight, maxCap);
    }

    function updateStrategy(
        address strategy,
        uint256 targetWeight,
        uint256 maxCap
    ) external onlyOwner {
        rebalancer.updateStrategy(strategy, targetWeight, maxCap);
        emit StrategyUpdated(strategy, targetWeight, maxCap);
    }

    function removeStrategy(address strategy) external onlyOwner {
        // First withdraw all funds from strategy
        IStrategy strategyContract = IStrategy(strategy);
        uint256 strategyAssets = strategyContract.totalAssets();
        
        if (strategyAssets > 0) {
            strategyContract.withdraw(strategyAssets);
        }
        
        rebalancer.removeStrategy(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                              REBALANCING
    //////////////////////////////////////////////////////////////*/

    function rebalance() external onlyKeeper returns (uint256 moveCount) {
        require(!emergencyShutdown, "StableYieldVault: emergency shutdown");
        
        uint256 gasStart = gasleft();
        uint256 vaultTotalAssets = totalAssets();
        uint256 idleAssets = asset.balanceOf(address(this));
        
        // Execute rebalancing
        Rebalancer.RebalanceMove[] memory moves = rebalancer.rebalance(vaultTotalAssets, idleAssets);
        
        moveCount = moves.length;
        lastRebalance = block.timestamp;
        
        uint256 gasUsed = gasStart - gasleft();
        emit Rebalance(moveCount, gasUsed);
    }

    function checkRebalanceNeeded() external view returns (bool needed, uint256 maxDeviation) {
        return rebalancer.checkRebalanceNeeded(totalAssets());
    }

    function _checkRebalanceNeeded() internal {
        (bool needed, uint256 deviation) = rebalancer.checkRebalanceNeeded(totalAssets());
        
        // Auto-rebalance if deviation > 10% and it's been > 1 hour since last rebalance
        if (needed && deviation > 1000 && block.timestamp > lastRebalance + 1 hours) {
            try this.rebalance() returns (uint256) {
                // Rebalance succeeded
            } catch {
                // Rebalance failed, continue normally
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               HARVESTING
    //////////////////////////////////////////////////////////////*/

    function harvest(address strategy) external onlyKeeper returns (uint256 gain, uint256 loss) {
        (gain, loss) = IStrategy(strategy).report();
        
        if (gain > 0) {
            totalGainRealized += gain;
        }
        if (loss > 0) {
            totalLossRealized += loss;
        }
        
        lastReport = block.timestamp;
        emit Harvest(strategy, gain, loss);
        
        // Accrue performance fees on gains
        if (gain > 0) {
            _accrueFees();
        }
    }

    function harvestAll() external onlyKeeper {
        address[] memory strategies = rebalancer.getActiveStrategies();
        
        for (uint256 i = 0; i < strategies.length; i++) {
            try this.harvest(strategies[i]) {
                // Harvest succeeded
            } catch {
                // Harvest failed for this strategy, continue with others
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                               FEE MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _accrueFees() internal {
        uint256 vaultTotalAssets = totalAssets();
        uint256 vaultTotalShares = totalSupply;
        
        if (vaultTotalShares == 0) return;
        
        // Accrue management fees
        uint256 managementFeeShares = feeController.accrueManagementFee(vaultTotalAssets, vaultTotalShares);
        
        // Accrue performance fees
        uint256 performanceFeeShares = feeController.accruePerformanceFee(vaultTotalAssets, vaultTotalShares);
        
        // Mint fee shares to fee recipient
        uint256 totalFeeShares = managementFeeShares + performanceFeeShares;
        if (totalFeeShares > 0) {
            _mint(feeController.feeRecipient(), totalFeeShares);
        }
    }

    function accrueFees() external onlyKeeper {
        _accrueFees();
    }

    /*//////////////////////////////////////////////////////////////
                             LIQUIDITY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function _ensureLiquidity(uint256 requiredAssets) internal {
        uint256 idleAssets = asset.balanceOf(address(this));
        
        if (idleAssets >= requiredAssets) {
            return; // Sufficient idle liquidity
        }
        
        uint256 shortfall = requiredAssets - idleAssets;
        address[] memory strategies = rebalancer.getActiveStrategies();
        
        // Withdraw from strategies to meet liquidity needs
        for (uint256 i = 0; i < strategies.length && shortfall > 0; i++) {
            IStrategy strategy = IStrategy(strategies[i]);
            uint256 maxWithdraw = strategy.maxWithdraw(address(this));
            uint256 withdrawAmount = shortfall > maxWithdraw ? maxWithdraw : shortfall;
            
            if (withdrawAmount > 0) {
                try strategy.withdraw(withdrawAmount) {
                    shortfall = shortfall > withdrawAmount ? shortfall - withdrawAmount : 0;
                } catch {
                    // Strategy withdrawal failed, continue with next strategy
                    continue;
                }
            }
        }
        
        require(shortfall == 0, "StableYieldVault: insufficient liquidity");
    }

    /*//////////////////////////////////////////////////////////////
                             EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyPauser {
        paused = true;
        emit VaultPaused(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit VaultPaused(false);
    }

    function emergencyShutdownVault() external onlyOwner {
        emergencyShutdown = true;
        paused = true;
        
        // Pause all strategies
        address[] memory strategies = rebalancer.getActiveStrategies();
        for (uint256 i = 0; i < strategies.length; i++) {
            try IStrategy(strategies[i]).pause() {
                // Strategy paused successfully
            } catch {
                // Strategy pause failed, continue
            }
        }
        
        emit EmergencyShutdown(true);
    }

    function emergencyWithdrawFromStrategy(address strategy) external onlyOwner {
        require(emergencyShutdown, "StableYieldVault: not in emergency");
        
        IStrategy strategyContract = IStrategy(strategy);
        uint256 strategyAssets = strategyContract.totalAssets();
        
        if (strategyAssets > 0) {
            strategyContract.withdraw(strategyAssets);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getVaultMetrics() external view returns (
        uint256 vaultTotalAssets,
        uint256 strategyAssets,
        uint256 idleAssets,
        uint256 totalShares,
        uint256 sharePrice,
        bool isPaused,
        bool isShutdown
    ) {
        vaultTotalAssets = totalAssets();
        strategyAssets = rebalancer.getTotalStrategyAssets();
        idleAssets = asset.balanceOf(address(this));
        totalShares = totalSupply;
        sharePrice = totalShares > 0 ? vaultTotalAssets.mulDivDown(1e18, totalShares) : 1e18;
        isPaused = paused;
        isShutdown = emergencyShutdown;
    }

    function getStrategyAllocations() external view returns (
        address[] memory strategies,
        uint256[] memory allocations,
        uint256[] memory weights,
        uint256[] memory caps
    ) {
        strategies = rebalancer.getActiveStrategies();
        uint256 length = strategies.length;
        
        allocations = new uint256[](length);
        weights = new uint256[](length);
        caps = new uint256[](length);
        
        for (uint256 i = 0; i < length; i++) {
            allocations[i] = IStrategy(strategies[i]).totalAssets();
            (weights[i], caps[i],) = rebalancer.strategies(strategies[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setWithdrawBuffer(uint256 buffer) external onlyOwner {
        rebalancer.setWithdrawBuffer(buffer);
    }

    function setMaxMovePerTx(uint256 maxMove) external onlyOwner {
        rebalancer.setMaxMovePerTx(maxMove);
    }

    function setFeeRecipient(address recipient) external onlyOwner {
        feeController.setFeeRecipient(recipient);
    }

    function setManagementFee(uint256 feeBps) external onlyOwner {
        feeController.setManagementFee(feeBps);
    }

    function setPerformanceFee(uint256 feeBps) external onlyOwner {
        feeController.setPerformanceFee(feeBps);
    }

    function recoverToken(address token, uint256 amount) external onlyOwner {
        require(token != address(asset), "StableYieldVault: cannot recover vault asset");
        IERC20(token).safeTransfer(accessController.owner(), amount);
    }
}