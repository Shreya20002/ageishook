// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./GuardianHook.sol";

contract GuardianHookFactory {
    event GuardianHookDeployed(address indexed hook, bytes32 indexed salt, address indexed poolManager);

    function deploy(address poolManager, address callbackSender, address admin, bytes32 salt)
        external
        returns (GuardianHook hook)
    {
        hook = new GuardianHook{salt: salt}(poolManager, callbackSender, admin);
        emit GuardianHookDeployed(address(hook), salt, poolManager);
    }
}
