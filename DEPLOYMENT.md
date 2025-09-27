# Nexus Contracts Deployment Guide

This guide provides step-by-step instructions for deploying NexusEscrow and NexusSettler contracts to any EVM-compatible network.
## Prerequisites

1. **Foundry installed**: Ensure you have Foundry installed on your system
2. **Private key**: Have a private key with sufficient ETH for gas fees
3. **RPC access**: Access to your target network's RPC endpoint
4. **API keys**: Etherscan/Arbiscan API keys for contract verification (optional)

## Setup

### 1. Environment Configuration

Copy the example environment file and configure it:

```bash
cp .env.example .env
```

Edit `.env` with your actual values:

```bash
# Required: Your deployer private key (without 0x prefix)
PRIVATE_KEY=your_private_key_here

# Optional: For contract verification
ETHERSCAN_API_KEY=your_etherscan_api_key_here

# Gas Configuration
GAS_PRICE=1000000000  # 1 gwei
GAS_LIMIT=3000000
```

### 2. Load Environment Variables

```bash
source .env
```

## Deployment Commands

The deployment script is chain-agnostic and works with any EVM-compatible network. Forge provides built-in verification with the `--verify` flag.

### Basic Deployment (No Verification)

```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url <YOUR_RPC_URL> \
    --broadcast \
    -vvvv
```

### Deployment with Automatic Verification

```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url <YOUR_RPC_URL> \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

## Network Examples

### Arbitrum Sepolia
```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url https://sepolia-rollup.arbitrum.io/rpc \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

### Ethereum Sepolia
```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url https://rpc.sepolia.org \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

### Arbitrum One
```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url https://arb1.arbitrum.io/rpc \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

### Base Mainnet
```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url https://mainnet.base.org \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    -vvvv
```

## Deployment Process

The deployment script will:

1. **Display deployment info** - Shows deployer address, balance, and chain ID
2. **Deploy NexusEscrow** - A simple escrow contract for holding tokens
3. **Deploy NexusSettler** - The main settler contract using the escrow address
4. **Show verification commands** - Provides ready-to-copy verification commands as backup
5. **Auto-verify contracts** - Forge automatically verifies contracts when `--verify` flag is used

## Verification

### Automatic Verification

Forge handles verification automatically when you use the `--verify` flag. It will:
- Detect constructor arguments automatically
- Submit source code to the block explorer
- Handle flattening and compilation settings
- Retry on failures

### Manual Verification (Backup)

If automatic verification fails, the deployment script outputs manual verification commands:

```bash
# Example output from deployment script:
forge verify-contract 0x123... src/NexusEscrow.sol:NexusEscrow --chain-id 421614
forge verify-contract 0x456... src/NexusSettler.sol:NexusSettler --chain-id 421614 --constructor-args 0x000...
```

### Verification Troubleshooting

If verification fails:

1. **Wait and retry**: Sometimes block explorers are slow to index
2. **Check API key**: Ensure your Etherscan API key is valid
3. **Manual verification**: Use the commands output by the deployment script
4. **Check constructor args**: Ensure they match exactly

## Post-Deployment

### 1. Verify Deployment

Check that both contracts are deployed correctly:

```bash
# Check NexusEscrow
cast code <ESCROW_ADDRESS> --rpc-url <RPC_URL>

# Check NexusSettler
cast code <SETTLER_ADDRESS> --rpc-url <RPC_URL>

# Verify escrow address in NexusSettler
cast call <SETTLER_ADDRESS> "escrow()" --rpc-url <RPC_URL>
```

### 2. Check Verification Status

Visit the block explorer to confirm contracts are verified:
- Look for the green checkmark next to contract addresses
- Ensure source code is readable
- Verify constructor parameters are correct

## Common Networks

| Network | Chain ID | RPC URL | Explorer |
|---------|----------|---------|----------|
| Arbitrum Sepolia | 421614 | https://sepolia-rollup.arbitrum.io/rpc | https://sepolia.arbiscan.io |
| Ethereum Sepolia | 11155111 | https://rpc.sepolia.org | https://sepolia.etherscan.io |
| Arbitrum One | 42161 | https://arb1.arbitrum.io/rpc | https://arbiscan.io |
| Base Mainnet | 8453 | https://mainnet.base.org | https://basescan.org |
| Polygon | 137 | https://polygon-rpc.com | https://polygonscan.com |

## Gas Estimates

Approximate gas costs for deployment:

- **NexusEscrow**: ~500,000 gas
- **NexusSettler**: ~2,500,000 gas
- **Total**: ~3,000,000 gas

## Troubleshooting

### Common Issues

1. **Insufficient gas**: Increase gas limit with `--gas-limit` flag
2. **RPC timeout**: Try a different RPC provider or add `--slow` flag
3. **Verification fails**: Wait a few minutes and use manual verification commands
4. **Nonce issues**: Check if transactions are pending
5. **API rate limits**: Wait before retrying verification

### Debug Commands

```bash
# Check account balance
cast balance <YOUR_ADDRESS> --rpc-url <RPC_URL>

# Check nonce
cast nonce <YOUR_ADDRESS> --rpc-url <RPC_URL>

# Estimate gas for deployment (dry run)
forge script script/Deploy.s.sol:DeployScript --rpc-url <RPC_URL>

# Deploy with custom gas settings
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url <RPC_URL> \
    --broadcast \
    --gas-limit 4000000 \
    --gas-price 2000000000

# Deploy with slower verification
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url <RPC_URL> \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_API_KEY \
    --slow \
    -vvvv
```

## Security Notes

- ⚠️ **Never commit your `.env` file** - it contains your private key
- ⚠️ **Use a dedicated deployment wallet** - don't use your main wallet
- ⚠️ **Test on testnets first** - always deploy to testnets before mainnet
- ⚠️ **Verify contract source code** - ensure contracts are verified on block explorers
- ⚠️ **Double-check RPC URLs** - ensure you're deploying to the correct network
- ⚠️ **Backup deployment info** - save contract addresses and transaction hashes

## Example Deployment Output

```
=== NEXUS DEPLOYMENT ===
Deployer: 0x742d35Cc6634C0532925a3b8D8C8b5d4b8b8b8b8
Balance: 1000000000000000000
Chain ID: 421614
Block number: 12345678
========================

Deploying NexusEscrow...
NexusEscrow deployed at: 0x123...

Deploying NexusSettler...
NexusSettler deployed at: 0x456...

=== DEPLOYMENT COMPLETE ===
Chain ID: 421614
NexusEscrow: 0x123...
NexusSettler: 0x456...
===========================

=== VERIFICATION COMMANDS ===
To verify NexusEscrow:
forge verify-contract 0x123... src/NexusEscrow.sol:NexusEscrow --chain-id 421614

To verify NexusSettler:
forge verify-contract 0x456... src/NexusSettler.sol:NexusSettler --chain-id 421614 --constructor-args 0x000...
=============================
```

Save the contract addresses for future reference and integration!
