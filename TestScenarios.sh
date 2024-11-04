#!/bin/bash

# Function to run tests with current environment configuration
run_test() {
    echo "Running tests with configuration:"
    echo "IS_TOKEN_0=${IS_TOKEN_0}"
    echo "USING_ETH=${USING_ETH}"
    echo "FEE=${FEE}"
    echo "PROTOCOL_FEE=${PROTOCOL_FEE}"
    echo "----------------------------------------"
    
    # Export the variables
    export IS_TOKEN_0
    export USING_ETH
    export FEE
    export PROTOCOL_FEE
    
    # Run forge test and capture exit code
    forge test --fuzz-runs 65536
    local test_result=$?
    
    echo "----------------------------------------"
    if [ $test_result -eq 0 ]; then
        echo "✅ Tests passed"
    else
        echo "❌ Tests failed"
    fi
    echo "----------------------------------------"
    echo ""
    
    return $test_result
}

# Initialize with default values
IS_TOKEN_0="false"
USING_ETH="false"
FEE=0
PROTOCOL_FEE=0

# Array to track failed configurations
failed_configs=()

# Test Case 1: IS_TOKEN_0 = true
echo "🔍 Test Case 1: IS_TOKEN_0 = true"
IS_TOKEN_0="true"
run_test || failed_configs+=("Case 1: IS_TOKEN_0=true")

# Test Case 2: IS_TOKEN_0 = false
echo "🔍 Test Case 2: IS_TOKEN_0 = false"
IS_TOKEN_0="false"
run_test || failed_configs+=("Case 2: IS_TOKEN_0=false")

# Test Case 3: USING_ETH = true
echo "🔍 Test Case 3: USING_ETH = true"
USING_ETH="true"
run_test || failed_configs+=("Case 3: USING_ETH=true")

# Test Case 4: IS_TOKEN_0=true and FEE=30
echo "🔍 Test Case 4: IS_TOKEN_0=true and FEE=30"
IS_TOKEN_0="true"
USING_ETH="false"
FEE=30
run_test || failed_configs+=("Case 4: IS_TOKEN_0=true, FEE=30")

# Test Case 5: IS_TOKEN_0=false and FEE=30
echo "🔍 Test Case 5: IS_TOKEN_0=false and FEE=30"
IS_TOKEN_0="false"
FEE=30
run_test || failed_configs+=("Case 5: IS_TOKEN_0=false, FEE=30")

# Test Case 6: USING_ETH=true, IS_TOKEN_0=false and FEE=30
echo "🔍 Test Case 6: USING_ETH=true, IS_TOKEN_0=false and FEE=30"
USING_ETH="true"
IS_TOKEN_0="false"
FEE=30
run_test || failed_configs+=("Case 6: USING_ETH=true, IS_TOKEN_0=false and FEE=30")

# Test Case 7: IS_TOKEN_0=true, FEE=30, PROTOCOL_FEE=50
echo "🔍 Test Case 7: IS_TOKEN_0=true, FEE=30, PROTOCOL_FEE=50"
USING_ETH="false"
IS_TOKEN_0="true"
FEE=30
PROTOCOL_FEE=50
run_test || failed_configs+=("Case 7: IS_TOKEN_0=true, FEE=30, PROTOCOL_FEE=50")

# Test Case 8: IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50
echo "🔍 Test Case 8: IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50"
IS_TOKEN_0="false"
run_test || failed_configs+=("Case 8: IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50")

# Test Case 9: USING_ETH=true, IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50
echo "🔍 Test Case 9: USING_ETH=true, IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50"
USING_ETH="true"
IS_TOKEN_0="false"
run_test || failed_configs+=("Case 9: USING_ETH=true, IS_TOKEN_0=false, FEE=30, PROTOCOL_FEE=50")

# Print summary
echo "================ Test Summary ================"
if [ ${#failed_configs[@]} -eq 0 ]; then
    echo "✅ All test configurations passed!"
else
    echo "❌ The following configurations failed:"
    for config in "${failed_configs[@]}"; do
        echo "  - $config"
    done
fi
