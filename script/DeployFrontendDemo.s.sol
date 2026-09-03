// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/FrontendDemoPoolManager.sol";

contract DeployFrontendDemoScript is Script {
    function run() external returns (FrontendDemoPoolManager demo) {
        vm.startBroadcast();
        demo = new FrontendDemoPoolManager();
        demo.initializeDemo();
        vm.stopBroadcast();

        console2.log("AegisHook frontend demo deployed");
        console2.log("NEXT_PUBLIC_DEMO_MANAGER_ADDRESS=", address(demo));
        console2.log("NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS=", address(demo.guardianHook()));
        console2.log("Pool ID:");
        console2.logBytes32(demo.poolId());
    }
}
