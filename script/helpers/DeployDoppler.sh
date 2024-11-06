#!/bin/bash
echo "Deploying Doppler hook..."
output=$(forge script ./script/DeployDoppler.sol --fork-url http://localhost:8545 --tc DeployDoppler --broadcast)

echo "Doppler hook deployed successfully"