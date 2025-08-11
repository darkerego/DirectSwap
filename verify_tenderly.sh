#!/usr/bin/env bash
CONTRACT_ADDRESS=$1
CONTRACT_NAME=$2
SOURCE_FILE=$3
SOLIDITY_VERSION=${4-"0.8.30"}
OPT_RUNS=${5-0}
VIA_IR=${6-false}

echo "Parameters : "
echo "Address: $CONTRACT_ADDRESS"
echo "Contract Name: $CONTRACT_NAME"
echo "Contract File: ./$SOURCE_FILE"
echo "Solidity Version $SOLIDITY_VERSION"
echo "Optimizer Runs: $OPT_RUNS"
echo "Via IR:" "$VIA_IR"

read -rp "ok ? "
# shellcheck disable=SC2046
export $(< .env)
export TENDERLY_ACCESS_KEY=$TENDERLY_ACCESS_KEY
export TENDERLY_VIRTUAL_TESTNET_RPC_URL="$TENDERLY_VIRTUAL_TESTNET_RPC_URL"
export TENDERLY_VERIFIER_URL="${TENDERLY_VIRTUAL_TESTNET_RPC_URL}/verify/etherscan"

if [[ "$OPT_RUNS" -gt 0 ]] ; then
  additional_args="  --optimizer-runs $OPT_RUNS"
else
  additional_args=''
fi

if [[ $VIA_IR ]]; then
  additional_args+=' --via-ir'
fi
#
#forge verify-contract \
 #    --chain-id 11155111 \
 #    --num-of-optimizations 1000000 \
 #    --watch \
 #    --constructor-args $(cast abi-encode "constructor(string,string,uint256,uint256)" "ForgeUSD" "FUSD" 18 1000000000000000000000) \
 #    --verifier etherscan \
 #    --etherscan-api-key <your_etherscan_api_key> \
 #    --compiler-version v0.8.10+commit.fc410830 \
 #    <CONTRACT_ADDRESS> \
 #    src/MyToken.sol:MyToken

cmd="forge verify-contract --chain-id 8453  --verifier-url $TENDERLY_VERIFIER_URL --watch --etherscan-api-key $TENDERLY_ACCESS_KEY  --compiler-version $SOLIDITY_VERSION ${additional_args} $CONTRACT_ADDRESS $SOURCE_FILE:$CONTRACT_NAME"
echo Running
echo "$cmd"
eval "$cmd"

