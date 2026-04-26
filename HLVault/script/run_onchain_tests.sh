#!/bin/bash
set -e

# ═══ Phase 2: On-Chain Testnet Tests ═══
# Deploys OnChainTestRunner and runs each test as a separate tx
# (HyperEVM block gas limit is ~3M, so tests must be split)

RPC="${RPC_URL:-https://rpc.hyperliquid-testnet.xyz/evm}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Load env
if [ -f "$ROOT_DIR/keeper/.env" ]; then
    export $(grep -v '^#' "$ROOT_DIR/keeper/.env" | xargs)
fi

if [ -z "$KEEPER_PRIVATE_KEY" ]; then
    echo "ERROR: KEEPER_PRIVATE_KEY not set"
    exit 1
fi

DEPLOYER=$(cast wallet address --private-key "$KEEPER_PRIVATE_KEY")
BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether)
echo "=== Phase 2: On-Chain Testnet Tests ==="
echo "Deployer: $DEPLOYER"
echo "Balance:  $BALANCE HYPE"
echo "RPC:      $RPC"
echo ""

# Step 1: Build
echo "--- Building ---"
cd "$ROOT_DIR"
forge build --silent

# Step 2: Deploy
echo "--- Deploying OnChainTestRunner ---"
DEPLOY_OUT=$(forge create script/TestOnChain.s.sol:OnChainTestRunner \
    --rpc-url "$RPC" \
    --private-key "$KEEPER_PRIVATE_KEY" \
    --broadcast 2>&1)

RUNNER=$(echo "$DEPLOY_OUT" | grep "Deployed to:" | awk '{print $3}')
if [ -z "$RUNNER" ]; then
    echo "Deploy failed:"
    echo "$DEPLOY_OUT"
    exit 1
fi
echo "TestRunner: $RUNNER"
echo ""

# Step 3: Run each test as a separate tx
TOTAL_OK=0
TOTAL_FAIL=0

run_test() {
    local name=$1
    local sig=$2
    echo -n "  $name ... "
    local TX_OUT=$(cast send "$RUNNER" "$sig" \
        --rpc-url "$RPC" \
        --private-key "$KEEPER_PRIVATE_KEY" \
        --gas-limit 2900000 2>&1)
    local STATUS=$(echo "$TX_OUT" | grep "^status" | awk '{print $2}')
    if [ "$STATUS" = "1" ]; then
        echo "OK"
        TOTAL_OK=$((TOTAL_OK + 1))
    else
        echo "FAILED"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        echo "$TX_OUT" | grep -E "transactionHash|gasUsed" | sed 's/^/    /'
    fi
}

echo "--- Running Tests ---"
run_test "Precompiles (spot prices)" "testPrecompiles()"
run_test "Factory state"             "testFactory()"
run_test "Vault views (grossAssets)" "testVaultViews()"
run_test "Vault state (phase, alloc)" "testVaultState()"

echo ""

# Step 4: Read cumulative results from contract
PASSED=$(cast call "$RUNNER" "passed()(uint256)" --rpc-url "$RPC")
FAILED=$(cast call "$RUNNER" "failed()(uint256)" --rpc-url "$RPC")

echo "=== RESULTS ==="
echo "  TX OK:     $TOTAL_OK / $((TOTAL_OK + TOTAL_FAIL))"
echo "  Assertions passed: $PASSED"
echo "  Assertions failed: $FAILED"
echo ""

FINAL_BALANCE=$(cast balance "$DEPLOYER" --rpc-url "$RPC" --ether)
echo "  Gas spent: $(echo "$BALANCE - $FINAL_BALANCE" | bc) HYPE"
echo ""

if [ "$FAILED" = "0" ] && [ "$TOTAL_FAIL" = "0" ]; then
    echo "ALL TESTS PASSED"
else
    echo "SOME TESTS FAILED"
    exit 1
fi
