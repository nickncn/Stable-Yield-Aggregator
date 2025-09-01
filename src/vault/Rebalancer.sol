// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {IStrategy} from "../interfaces/IStrategy.sol";
import {FixedPointMathLib} from "../lib/FixedPointMathLib.sol";
import {SafeTransferLib} from "../lib/SafeTransferLib.sol";

/**
 * @title Rebalancer
 * @notice Manages strategy allocation weights, caps, and rebalancing logic
 * @dev Maintains target weights while respecting individual caps and liquidity buffers
 */
contract Rebalancer {
    using SafeTransferLib for IERC20;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Rebalance(
        address indexed strategy,
        bool indexed isDeposit,
        uint256 amount,
        uint256 newAllocation
    );
    event StrategyAdded(address indexed strategy, uint256 targetWeight, uint256 maxCap);
    event StrategyUpdated(address indexed strategy, uint256 targetWeight, uint256 maxCap);
    event StrategyRemoved(address indexed strategy);
    event WithdrawBufferUpdated(uint256 oldBuffer, uint256 newBuffer);
    event MaxMovePerTxUpdated(uint256 oldMax, uint256 newMax);

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    struct StrategyConfig {
        uint256 targetWeight;  // Target allocation weight (in BPS, 10000 = 100%)
        uint256 maxCap;        // Maximum assets this strategy can hold
        bool active;           // Whether strategy is active
    }

    IERC20 public immutable asset;
    
    mapping(address => StrategyConfig) public strategies;
    address[] public strategyList;
    
    uint256 public withdrawBuffer = 800;     // 8% buffer in BPS for withdrawals
    uint256 public maxMovePerTx = 100_000e6; // Max USDC to move per rebalance tx
    
    uint256 public constant BPS_SCALE = 10_000;
    uint256 public constant MAX_WITHDRAW_BUFFER = 2000; // 20% max buffer

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS  
    //////////////////////////////////////////////////////////////*/

    modifier onlyActiveStrategy(address strategy) {
        require(strategies[strategy].active, "Rebalancer: strategy not active");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 _asset) {
        asset = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                           STRATEGY MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    function addStrategy(
        address strategy,
        uint256 targetWeight,
        uint256 maxCap
    ) external {
        require(strategy != address(0), "Rebalancer: zero strategy");
        require(!strategies[strategy].active, "Rebalancer: strategy already active");
        require(targetWeight <= BPS_SCALE, "Rebalancer: weight too high");
        require(maxCap > 0, "Rebalancer: zero cap");
        
        // Verify strategy implements correct interface
        require(IStrategy(strategy).asset() == asset, "Rebalancer: asset mismatch");
        
        strategies[strategy] = StrategyConfig({
            targetWeight: targetWeight,
            maxCap: maxCap,
            active: true
        });
        
        strategyList.push(strategy);
        
        emit StrategyAdded(strategy, targetWeight, maxCap);
    }

    function updateStrategy(
        address strategy,
        uint256 targetWeight,
        uint256 maxCap
    ) external onlyActiveStrategy(strategy) {
        require(targetWeight <= BPS_SCALE, "Rebalancer: weight too high");
        require(maxCap > 0, "Rebalancer: zero cap");
        
        strategies[strategy].targetWeight = targetWeight;
        strategies[strategy].maxCap = maxCap;
        
        emit StrategyUpdated(strategy, targetWeight, maxCap);
    }

    function removeStrategy(address strategy) external onlyActiveStrategy(strategy) {
        // Mark as inactive but keep in list for historical purposes
        strategies[strategy].active = false;
        strategies[strategy].targetWeight = 0;
        
        emit StrategyRemoved(strategy);
    }

    /*//////////////////////////////////////////////////////////////
                            REBALANCING LOGIC
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Execute rebalancing to move toward target weights
     * @param totalVaultAssets Total assets controlled by vault (including idle)
     * @param idleAssets Assets currently idle in vault
     * @return moves Array of rebalancing moves executed
     */
    function rebalance(
        uint256 totalVaultAssets,
        uint256 idleAssets
    ) external returns (RebalanceMove[] memory moves) {
        require(totalVaultAssets > 0, "Rebalancer: no assets to rebalance");
        
        // Calculate required buffer amount
        uint256 requiredBuffer = totalVaultAssets.mulDivUp(withdrawBuffer, BPS_SCALE);
        
        // Available assets for strategy allocation (total - buffer)
        uint256 allocatableAssets = totalVaultAssets > requiredBuffer 
            ? totalVaultAssets - requiredBuffer 
            : 0;

        // Get current allocations and calculate target allocations
        (uint256[] memory currentAllocations, uint256[] memory targetAllocations) = 
            _calculateAllocations(allocatableAssets);
        
        // Calculate and execute moves
        moves = _executeMoves(currentAllocations, targetAllocations, idleAssets, requiredBuffer);
    }

    struct RebalanceMove {
        address strategy;
        bool isDeposit;     // true = deposit, false = withdraw
        uint256 amount;
    }

    /**
     * @notice Calculate current and target allocations for all active strategies
     */
    function _calculateAllocations(
        uint256 allocatableAssets
    ) internal view returns (uint256[] memory current, uint256[] memory target) {
        uint256 activeCount = 0;
        
        // Count active strategies
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) activeCount++;
        }
        
        current = new uint256[](activeCount);
        target = new uint256[](activeCount);
        
        uint256 idx = 0;
        uint256 totalWeight = 0;
        
        // Calculate total weight and current allocations
        for (uint256 i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy].active) {
                current[idx] = IStrategy(strategy).totalAssets();
                totalWeight += strategies[strategy].targetWeight;
                idx++;
            }
        }
        
        // Calculate target allocations based on weights
        idx = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy].active) {
                if (totalWeight > 0) {
                    uint256 targetAmount = allocatableAssets.mulDivDown(
                        strategies[strategy].targetWeight,
                        totalWeight
                    );
                    // Respect individual strategy caps
                    target[idx] = targetAmount > strategies[strategy].maxCap 
                        ? strategies[strategy].maxCap 
                        : targetAmount;
                }
                idx++;
            }
        }
    }

    /**
     * @notice Execute rebalancing moves based on current vs target allocations
     */
    function _executeMoves(
        uint256[] memory currentAllocations,
        uint256[] memory targetAllocations,
        uint256 idleAssets,
        uint256 requiredBuffer
    ) internal returns (RebalanceMove[] memory moves) {
        uint256 moveCount = 0;
        RebalanceMove[] memory tempMoves = new RebalanceMove[](strategyList.length);
        
        uint256 idx = 0;
        uint256 availableForMoves = idleAssets > requiredBuffer ? idleAssets - requiredBuffer : 0;
        
        // First pass: identify withdrawals (free up capital)
        for (uint256 i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (!strategies[strategy].active) continue;
            
            uint256 current = currentAllocations[idx];
            uint256 target = targetAllocations[idx];
            
            if (current > target) {
                uint256 withdrawAmount = current - target;
                
                // Cap by max move per tx and available liquidity
                uint256 maxWithdraw = IStrategy(strategy).maxWithdraw(address(this));
                withdrawAmount = withdrawAmount > maxWithdraw ? maxWithdraw : withdrawAmount;
                withdrawAmount = withdrawAmount > maxMovePerTx ? maxMovePerTx : withdrawAmount;
                
                if (withdrawAmount > 0) {
                    // Execute withdrawal
                    IStrategy(strategy).withdraw(withdrawAmount);
                    availableForMoves += withdrawAmount;
                    
                    tempMoves[moveCount] = RebalanceMove({
                        strategy: strategy,
                        isDeposit: false,
                        amount: withdrawAmount
                    });
                    moveCount++;
                    
                    emit Rebalance(strategy, false, withdrawAmount, current - withdrawAmount);
                }
            }
            idx++;
        }
        
        // Second pass: identify deposits (deploy capital)
        idx = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (!strategies[strategy].active) continue;
            
            uint256 current = currentAllocations[idx];
            uint256 target = targetAllocations[idx];
            
            if (target > current && availableForMoves > 0) {
                uint256 depositAmount = target - current;
                
                // Cap by available idle assets and max move per tx
                depositAmount = depositAmount > availableForMoves ? availableForMoves : depositAmount;
                depositAmount = depositAmount > maxMovePerTx ? maxMovePerTx : depositAmount;
                
                // Cap by strategy capacity
                uint256 maxDeposit = IStrategy(strategy).maxDeposit(address(this));
                depositAmount = depositAmount > maxDeposit ? maxDeposit : depositAmount;
                
                if (depositAmount > 0) {
                    // Execute deposit
                    asset.safeTransfer(strategy, depositAmount);
                    IStrategy(strategy).deposit(depositAmount);
                    availableForMoves -= depositAmount;
                    
                    tempMoves[moveCount] = RebalanceMove({
                        strategy: strategy,
                        isDeposit: true,
                        amount: depositAmount
                    });
                    moveCount++;
                    
                    emit Rebalance(strategy, true, depositAmount, current + depositAmount);
                }
            }
            idx++;
        }
        
        // Resize moves array to actual count
        moves = new RebalanceMove[](moveCount);
        for (uint256 i = 0; i < moveCount; i++) {
            moves[i] = tempMoves[i];
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function getActiveStrategies() external view returns (address[] memory) {
        uint256 activeCount = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) activeCount++;
        }
        
        address[] memory active = new address[](activeCount);
        uint256 idx = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) {
                active[idx] = strategyList[i];
                idx++;
            }
        }
        return active;
    }

    function getTotalStrategyAssets() external view returns (uint256 total) {
        for (uint256 i = 0; i < strategyList.length; i++) {
            address strategy = strategyList[i];
            if (strategies[strategy].active) {
                total += IStrategy(strategy).totalAssets();
            }
        }
    }

    function checkRebalanceNeeded(
        uint256 totalVaultAssets
    ) external view returns (bool needed, uint256 maxDeviation) {
        if (totalVaultAssets == 0) return (false, 0);
        
        uint256 requiredBuffer = totalVaultAssets.mulDivUp(withdrawBuffer, BPS_SCALE);
        uint256 allocatableAssets = totalVaultAssets > requiredBuffer 
            ? totalVaultAssets - requiredBuffer 
            : 0;
        
        if (allocatableAssets == 0) return (false, 0);
        
        (uint256[] memory current, uint256[] memory target) = _calculateAllocations(allocatableAssets);
        
        // Check if any strategy deviates significantly from target
        uint256 idx = 0;
        for (uint256 i = 0; i < strategyList.length; i++) {
            if (strategies[strategyList[i]].active) {
                if (current[idx] > 0 || target[idx] > 0) {
                    uint256 deviation = current[idx] > target[idx] 
                        ? current[idx] - target[idx] 
                        : target[idx] - current[idx];
                    
                    uint256 deviationBps = target[idx] > 0 
                        ? deviation.mulDivDown(BPS_SCALE, target[idx])
                        : BPS_SCALE;
                    
                    if (deviationBps > maxDeviation) {
                        maxDeviation = deviationBps;
                    }
                    
                    // Consider rebalancing needed if deviation > 5%
                    if (deviationBps > 500) {
                        needed = true;
                    }
                }
                idx++;
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function setWithdrawBuffer(uint256 _withdrawBuffer) external {
        require(_withdrawBuffer <= MAX_WITHDRAW_BUFFER, "Rebalancer: buffer too high");
        
        uint256 oldBuffer = withdrawBuffer;
        withdrawBuffer = _withdrawBuffer;
        emit WithdrawBufferUpdated(oldBuffer, _withdrawBuffer);
    }

    function setMaxMovePerTx(uint256 _maxMovePerTx) external {
        require(_maxMovePerTx > 0, "Rebalancer: zero max move");
        
        uint256 oldMax = maxMovePerTx;
        maxMovePerTx = _maxMovePerTx;
        emit MaxMovePerTxUpdated(oldMax, _maxMovePerTx);
    }

    /*//////////////////////////////////////////////////////////////
                             ERROR HANDLING
    //////////////////////////////////////////////////////////////*/

    error RebalanceFailed(address strategy, string reason);
    error InsufficientLiquidity(address strategy, uint256 requested, uint256 available);
    error WeightSumExceeded(uint256 totalWeight);
}