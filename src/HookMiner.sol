// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";

library HookMiner {
    uint160 internal constant REQUIRED_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    error HookAddressNotFound();

    function hasRequiredFlags(address hookAddress) internal pure returns (bool) {
        return (uint160(hookAddress) & Hooks.ALL_HOOK_MASK) == REQUIRED_FLAGS;
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash)
        internal
        pure
        returns (address)
    {
        return address(
            uint160(
                uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))
            )
        );
    }

    function find(address deployer, bytes32 initCodeHash, uint256 startSalt, uint256 maxIterations)
        internal
        pure
        returns (bytes32 salt, address hookAddress)
    {
        for (uint256 i = 0; i < maxIterations; i++) {
            salt = bytes32(startSalt + i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (hasRequiredFlags(hookAddress)) {
                return (salt, hookAddress);
            }
        }

        revert HookAddressNotFound();
    }
}
