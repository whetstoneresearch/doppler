#!/bin/bash
echo "Deploying Doppler dependencies..."
output=$(forge script ./script/DeployDopplerFactory.sol --fork-url http://localhost:8545 --tc DeployDopplerFactory --broadcast)

update_env() {
    local key=$1
    local pattern=$2
    local env_file=".env"
    
    local address=$(echo "$output" | grep "$pattern" | awk '{print $NF}')
    
    if [ ! -z "$address" ]; then
        if [ -f "$env_file" ]; then
            if grep -q "^$key=" "$env_file"; then
                sed -i "s|^$key=.*|$key=\"$address\"|" "$env_file"
            else
                echo "$key=\"$address\"" >> "$env_file"
            fi
        else
            echo "$key=\"$address\"" > "$env_file"
        fi
        echo "Updated $key with address: $address"
    else
        echo "Warning: Could not find address for $key"
    fi
}

# Update each value in the .env file
update_env "MANAGER" "Manager:"
update_env "AIRLOCK" "Airlock:"
update_env "TOKEN_FACTORY" "TokenFactory:"
update_env "GOVERNANCE_FACTORY" "GovernanceFactory:"
update_env "MIGRATOR" "Migrator:"
update_env "DOPPLER_FACTORY" "DopplerFactory:"
update_env "V2_FACTORY" "V2Factory:"
update_env "V2_ROUTER" "V2Router:"
update_env "STATE_VIEW" "StateView:"
update_env "QUOTER" "Quoter"
update_env "SWAP_ROUTER" "SwapRouter"
update_env "CUSTOM_ROUTER" "Router"


echo "Environment file has been updated successfully"
