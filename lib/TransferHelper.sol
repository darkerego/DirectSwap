// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

abstract contract TransferHelper {
    error CallFailed(address,bytes4);
    error StaticCallFailed(address recipient, bytes data);
    error InsufficientAllowance(address token, address holder, uint256 amount);

    function thisBalance() internal view returns(uint b) {
        assembly {b := selfbalance()}
    }

    function codeSize(address) internal view returns (int256 size) {
        assembly {
            size := extcodesize(calldataload(0x04))
            }
    }

    function isContract(address addr) internal view returns(bool) {
        return codeSize(addr) > 0;
    }


    /*
    @dev Lowlevel static call to get a ERC20 token's owner's allowance for a given spender
    */

    function tokenAllowance(address tokenAddress, address ownerAddress, address spenderAddress) internal view returns(uint256 _allowance) {
        bytes memory _data = abi.encodeWithSelector(0xdd62ed3e, ownerAddress, spenderAddress);
        (bool _success, bytes memory allowanceData) = staticCall(tokenAddress, _data);
        require(_success, StaticCallFailed(tokenAddress, _data));
        _allowance = uint256(bytes32(allowanceData));
    }

    /*
    @dev Lowlevel static call to get a ERC20 token's balance
    */

    function tokenBalance(address tokenAddress, address accountAddress) internal view returns(uint256 bal) {
        bytes memory data = abi.encodeWithSelector(0x70a08231, accountAddress);
        (bool success, bytes memory balanceData) = staticCall(tokenAddress, data);
        require(success, StaticCallFailed(tokenAddress, data));
        bal = uint256(bytes32(balanceData));
    }
    /*
        @dev: Function to executeCall a transaction with arbitrary parameters.
        @dev: Warning: restrict access to this function!
    */
    function executeCall(

        address recipient,
        uint256 _value,
        bytes memory data
        ) internal returns(bytes memory retData) {
            // solhint-disable-next-line no-inline-assembly
       assembly {
            let success := eq(call(gas(), recipient, _value, add(data, 0x20), mload(data), 0x00, 0x00), 0x1)
            let retSize := returndatasize()
            retData := mload(0x40)
            mstore(0x40, add(retData, add(retSize, 0x20))) // Adjust free memory pointer
            mstore(retData, retSize) // Store the return size
            returndatacopy(add(retData, 0x20), 0, retSize) // Copy return data
            if iszero(success) {
                revert(retData, retSize)}
            }

        }

    function staticCall(address target, bytes memory callData) internal view returns (bool success, bytes memory data) {

        assembly {
            let size := mload(callData) // Get the data size
            let ptr := add(callData, 0x20) // Skip the length field

            success := staticcall(
                gas(),        // Gas limit
                target,       // Target address
                ptr,          // Input data pointer
                size,         // Input data size
                add(ptr, size), // Output data pointer
                0             // Output data size, will be updated later
            )
            if iszero(success) {
                mstore(0x00, 0xe10bf1cc)
                revert(0x00, 0x04)

            }

            let retSize := returndatasize()
            data := mload(0x40) // Fetch the free memory pointer
            mstore(0x40, add(data, add(retSize, 0x20))) // Adjust the free memory pointer
            mstore(data, retSize) // Store the return data size
            returndatacopy(add(data, 0x20), 0, retSize) // Copy the return data
        }
    }

    /// @dev Verifies that the last return was a successful `transfer*` call.

    function getLastTransferResult(
        address token
        ) internal view returns (bool success) {
        // solhint-disable-next-line no-inline-assembly
        assembly {
            let s := returndatasize()
            switch s
            case 0 {
                if iszero(extcodesize(token)) {
                    mstore(0x00, 0xa77cdf31)
                    mstore(0x04, token)
                    revert(0x00, 0x24)
                }
                success := 1
            }
            case 32 {
                returndatacopy(0, 0, s)
                success := iszero(iszero(mload(0)))
            }
            default {
                mstore(0x00, 0x30ae1b40)
                revert(0x00, 0x04)

            }
        }
    }

    /// @dev Wrapper around a call to the ERC20 function `approve` that
    /// @dev reverts also when the token returns `false`.
    function safeApprove(
        address token,
        address spender,
        uint256 amount
        ) internal {
        bytes4 selector_ = 0x095ea7b3;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, selector_)
            mstore(add(freeMemoryPointer, 4), and(spender, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), amount)
            if iszero(call(gas(), token, 0, freeMemoryPointer, 68, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    /// @dev Wrapper around a call to the ERC20 function `transfer` that
    /// @dev reverts also when the token returns `false`.
    function safeTransfer(
        address token,
        address to,
        uint256 value
        ) internal {
        bytes4 selector_ = 0xa9059cbb;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, selector_)
            mstore(add(freeMemoryPointer, 4), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), value)
            if iszero(call(gas(), token, 0, freeMemoryPointer, 68, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        if (! getLastTransferResult(token)) {
            revert CallFailed(token, selector_);
        }
    }

    /// @dev Wrapper around a call to the ERC20 function `transferFrom` that
    /// @dev reverts also when the token returns `false`.
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 value
        ) internal {
        bytes4 selector_ = 0x23b872dd;

        // solhint-disable-next-line no-inline-assembly
        assembly {
            let freeMemoryPointer := mload(0x40)
            mstore(freeMemoryPointer, selector_)
            mstore(add(freeMemoryPointer, 4), and(from, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 36), and(to, 0xffffffffffffffffffffffffffffffffffffffff))
            mstore(add(freeMemoryPointer, 68), value)
            if iszero(call(gas(), token, 0, freeMemoryPointer, 100, 0, 0)) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }

        if (! getLastTransferResult(token)) {
            revert CallFailed(token, selector_);
        }
    }
}