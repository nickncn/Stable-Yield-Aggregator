## Overview

![Stable Yield Aggregator Architecture](https://via.placeholder.com/600x400/1e1e1e/ffffff?text=Vault+%E2%86%92+Strategies+%E2%86%92+Protocols)

A production-ready ERC-4626 vault that automatically allocates USDC across multiple DeFi yield strategies (Aave V3, Compound V3, and a fixed-rate idle strategy). The vault optimizes yield while maintaining safety through caps, buffers, and automated rebalancing.

### Key Features

- **ERC-4626 Compliant**: Standard vault interface with proper USDC (6 decimals) handling
- **Multi-Strategy Allocation**: Pluggable strategies with configurable weights and caps
- **Automated Rebalancing**: On-chain policy maintaining target allocations and liquidity buffers
- **Fee Management**: Management fees (bps/year) and performance fees with high-watermark
- **Safety Rails**: Per-transaction limits, slippage protection, and pause mechanisms
- **Role-Based Access**: Owner, Keeper, and Pauser roles with minimal admin surface

### Safety Limits

- Per-strategy caps prevent concentration risk
- Withdrawal buffer (default 8%) ensures liquidity
- Slippage protection on strategy interactions
- Loss limits per transaction with clear revert messages
- Pause functionality for emergency stops

### Fees

- **Management Fee**: Charged annually as basis points on total assets
- **Performance Fee**: Charged on realized gains above high-watermark
- Fees minted as vault shares to designated recipient

### Rebalancing Policy

The vault automatically rebalances to maintain target weights:
- Aave V3: 50% (adjustable)
- Compound V3: 40% (adjustable) 
- Idle Strategy: 10% (adjustable)

Rebalancing respects individual strategy caps and maintains the withdrawal buffer.

## Quickstart

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup