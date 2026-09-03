// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/GuardianHook.sol";
import "../src/GuardianHookFactory.sol";
import "../src/HookMiner.sol";
import "../src/ReactiveContract.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

interface Vm {
    function envAddress(string calldata name) external returns (address);
    function envUint(string calldata name) external returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract DeployScript {
    function run()
        external
        returns (
            GuardianHookFactory guardianHookFactory,
            GuardianHook guardianHook,
            ReactiveContract reactiveContract,
            bytes32 hookSalt
        )
    {
        Vm vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

        address poolManager = vm.envAddress("POOL_MANAGER");
        address callbackSender = vm.envAddress("CALLBACK_SENDER");
        address hookAdmin = vm.envAddress("HOOK_ADMIN");
        address reactiveService = vm.envAddress("REACTIVE_SERVICE");
        address trustedReactiveRvmId = vm.envAddress("TRUSTED_REACTIVE_RVM_ID");
        address currency0Address = vm.envAddress("DEFAULT_CURRENCY0");
        address currency1Address = vm.envAddress("DEFAULT_CURRENCY1");
        uint24 fee = uint24(vm.envUint("DEFAULT_FEE"));
        int24 tickSpacing = int24(int256(vm.envUint("DEFAULT_TICK_SPACING")));
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        uint256 destinationChainId = vm.envUint("DESTINATION_CHAIN_ID");
        uint64 callbackGasLimit = uint64(vm.envUint("REACTIVE_CALLBACK_GAS_LIMIT"));
        uint256 saltStart = vm.envUint("HOOK_SALT_START");
        uint256 saltSearchLimit = vm.envUint("HOOK_SALT_SEARCH_LIMIT");

        if (currency1Address < currency0Address) {
            (currency0Address, currency1Address) = (currency1Address, currency0Address);
        }

        vm.startBroadcast();

        guardianHookFactory = new GuardianHookFactory();

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GuardianHook).creationCode, abi.encode(poolManager, callbackSender, hookAdmin)
            )
        );
        (hookSalt,) =
            HookMiner.find(address(guardianHookFactory), initCodeHash, saltStart, saltSearchLimit);

        guardianHook = guardianHookFactory.deploy(poolManager, callbackSender, hookAdmin, hookSalt);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0Address),
            currency1: Currency.wrap(currency1Address),
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(guardianHook))
        });

        bytes32 poolId = guardianHook.registerPool(key);
        guardianHook.setTrustedReactiveRvmId(trustedReactiveRvmId);

        reactiveContract = new ReactiveContract(
            reactiveService,
            originChainId,
            destinationChainId,
            address(guardianHook),
            poolId,
            callbackGasLimit
        );

        vm.stopBroadcast();
    }
}
