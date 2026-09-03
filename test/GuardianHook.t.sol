// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../src/GuardianHook.sol";
import "../src/GuardianHookFactory.sol";
import "../src/HookMiner.sol";
import "../src/ReactiveContract.sol";
import "../src/ReactivePrimitives.sol";
import { IExtsload } from "@uniswap/v4-core/src/interfaces/IExtsload.sol";
import { IExttload } from "@uniswap/v4-core/src/interfaces/IExttload.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { BalanceDelta, toBalanceDelta } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import { BeforeSwapDelta } from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";

interface Vm {
    function prank(address msgSender) external;
    function expectRevert(bytes4) external;
}

contract MockPoolManager is IExtsload, IExttload {
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    mapping(bytes32 => bytes32) internal slots;

    function setPoolState(bytes32 poolId, uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
        external
    {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        slots[stateSlot] = _encodeSlot0(sqrtPriceX96, tick, 0, 0);
        slots[bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET)] = bytes32(uint256(liquidity));
    }

    function callBeforeSwap(
        GuardianHook hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params
    ) external returns (bytes4, BeforeSwapDelta, uint24) {
        return hook.beforeSwap(sender, key, params, "");
    }

    function callAfterSwap(
        GuardianHook hook,
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta
    ) external returns (bytes4, int128) {
        return hook.afterSwap(sender, key, params, delta, "");
    }

    function extsload(bytes32 slot) external view returns (bytes32 value) {
        return slots[slot];
    }

    function extsload(bytes32 startSlot, uint256 nSlots)
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            values[i] = slots[bytes32(uint256(startSlot) + i)];
        }
    }

    function extsload(bytes32[] calldata querySlots)
        external
        view
        returns (bytes32[] memory values)
    {
        values = new bytes32[](querySlots.length);
        for (uint256 i = 0; i < querySlots.length; i++) {
            values[i] = slots[querySlots[i]];
        }
    }

    function exttload(bytes32) external pure returns (bytes32 value) {
        return value;
    }

    function exttload(bytes32[] calldata querySlots)
        external
        pure
        returns (bytes32[] memory values)
    {
        values = new bytes32[](querySlots.length);
    }

    function _encodeSlot0(uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
        internal
        pure
        returns (bytes32 data)
    {
        uint24 tickBits = uint24(uint24(int24(tick)));
        data = bytes32(
            uint256(sqrtPriceX96) | (uint256(tickBits) << 160) | (uint256(protocolFee) << 184)
                | (uint256(lpFee) << 208)
        );
    }
}

contract MockReactiveService is ISystemContract {
    uint256 internal constant EXPECTED_IGNORE =
        0xa65f96fc951c35ead38878e0f0b7a3c744a6f5ccc1476b313353ce31712313ad;

    struct Subscription {
        uint256 chainId;
        address contractAddress;
        uint256 topic0;
        uint256 topic1;
        uint256 topic2;
        uint256 topic3;
    }

    Subscription internal lastSubscription;

    function subscribe(
        uint256 chainId,
        address contractAddress,
        uint256 topic0,
        uint256 topic1,
        uint256 topic2,
        uint256 topic3
    ) external {
        lastSubscription = Subscription(chainId, contractAddress, topic0, topic1, topic2, topic3);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external { }

    function debt(address) external pure returns (uint256) {
        return 0;
    }

    receive() external payable { }

    function getLastSubscription() external view returns (Subscription memory) {
        return lastSubscription;
    }

    function expectedIgnore() external pure returns (uint256) {
        return EXPECTED_IGNORE;
    }
}

contract GuardianHookTest {
    using PoolIdLibrary for PoolKey;

    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint160 internal constant ALL_HOOK_MASK = uint160((1 << 14) - 1);
    uint160 internal constant REQUIRED_FLAGS = (1 << 7) | (1 << 6);

    address internal constant CALLBACK_SENDER = address(0xCB01);
    address internal constant VM_SERVICE = address(0x600D);
    uint256 internal constant ORIGIN_CHAIN_ID = 11155111;
    uint256 internal constant DESTINATION_CHAIN_ID = 11155111;
    uint64 internal constant CALLBACK_GAS_LIMIT = 250000;

    MockPoolManager internal poolManager;
    GuardianHookFactory internal hookFactory;
    GuardianHook internal guardianHook;
    ReactiveContract internal reactiveVmContract;
    PoolKey internal poolKey;
    bytes32 internal poolId;

    function setUp() public {
        poolManager = new MockPoolManager();
        hookFactory = new GuardianHookFactory();

        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GuardianHook).creationCode,
                abi.encode(address(poolManager), CALLBACK_SENDER, address(this))
            )
        );
        (bytes32 salt, address predictedHook) =
            HookMiner.find(address(hookFactory), initCodeHash, 0, 200000);
        guardianHook =
            hookFactory.deploy(address(poolManager), CALLBACK_SENDER, address(this), salt);

        assertEq(address(guardianHook), predictedHook);
        assertTrue(HookMiner.hasRequiredFlags(address(guardianHook)));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1000)),
            currency1: Currency.wrap(address(0x2000)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(guardianHook))
        });
        poolId = PoolId.unwrap(poolKey.toId());

        poolManager.setPoolState(poolId, uint160(1000), 10, 500);
        guardianHook.registerPool(poolKey);
        guardianHook.setTrustedReactiveRvmId(address(this));

        reactiveVmContract = new ReactiveContract(
            VM_SERVICE,
            ORIGIN_CHAIN_ID,
            DESTINATION_CHAIN_ID,
            address(guardianHook),
            poolId,
            CALLBACK_GAS_LIMIT
        );
    }

    function assertEq(uint256 left, uint256 right) internal pure {
        require(left == right, "assertEq(uint256) failed");
    }

    function assertEq(int256 left, int256 right) internal pure {
        require(left == right, "assertEq(int256) failed");
    }

    function assertEq(address left, address right) internal pure {
        require(left == right, "assertEq(address) failed");
    }

    function assertEq(bytes32 left, bytes32 right) internal pure {
        require(left == right, "assertEq(bytes32) failed");
    }

    function assertEq(string memory left, string memory right) internal pure {
        require(keccak256(bytes(left)) == keccak256(bytes(right)), "assertEq(string) failed");
    }

    function assertTrue(bool value) internal pure {
        require(value, "assertTrue failed");
    }

    function testDeployedHookHasExpectedPermissionBits() public view {
        uint160 masked = uint160(address(guardianHook)) & ALL_HOOK_MASK;
        assertEq(uint256(masked), uint256(REQUIRED_FLAGS));
    }

    function testRegistersPoolAndCapturesInitialState() public view {
        (bool registered, bool paused, uint160 sqrtPriceX96, int24 tick, uint128 liquidity,,,,) =
            guardianHook.getPoolState(poolId);

        assertTrue(registered);
        assertTrue(!paused);
        assertEq(uint256(sqrtPriceX96), 1000);
        assertEq(int256(tick), 10);
        assertEq(uint256(liquidity), 500);
    }

    function testOnlyPoolManagerCanInvokeHookCallbacks() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: 0 });

        vm.expectRevert(GuardianHook.NotPoolManager.selector);
        guardianHook.beforeSwap(address(this), poolKey, params, "");
    }

    function testBeforeSwapAndAfterSwapNormalPath() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: 0 });
        BalanceDelta delta = toBalanceDelta(10, -10);

        poolManager.callBeforeSwap(guardianHook, address(this), poolKey, params);
        poolManager.setPoolState(poolId, uint160(1100), 11, 500);
        poolManager.callAfterSwap(guardianHook, address(this), poolKey, params, delta);

        (
            ,
            ,
            uint160 sqrtPriceX96,
            int24 tick,
            uint128 liquidity,
            GuardianHook.ActionType lastAction,
            ,
            ,
        ) = guardianHook.getPoolState(poolId);

        assertEq(uint256(sqrtPriceX96), 1100);
        assertEq(int256(tick), 11);
        assertEq(uint256(liquidity), 500);
        assertEq(uint256(lastAction), uint256(GuardianHook.ActionType.Swap));
    }

    function testAfterSwapEmitsEmergencyAlertForNoOpPattern() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: 0 });
        BalanceDelta delta = toBalanceDelta(0, 0);

        poolManager.callBeforeSwap(guardianHook, address(this), poolKey, params);
        poolManager.setPoolState(poolId, uint160(1000), 10, 500);
        poolManager.callAfterSwap(guardianHook, address(this), poolKey, params, delta);

        (,,,,,,, string memory lastAlertReason,) = guardianHook.getPoolState(poolId);
        assertEq(lastAlertReason, "NO_OP_ALERT");
    }

    function testRejectsPausedPoolsInBeforeSwap() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: 0 });
        guardianHook.pausePool(poolId, "MANUAL_PAUSE");

        vm.expectRevert(GuardianHook.PoolPaused.selector);
        poolManager.callBeforeSwap(guardianHook, address(this), poolKey, params);
    }

    function testRejectsZeroSpecifiedAmount() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0 });

        vm.expectRevert(GuardianHook.InvalidSwap.selector);
        poolManager.callBeforeSwap(guardianHook, address(this), poolKey, params);
    }

    function testReactivePauseOnlyAcceptsConfiguredCallbackSender() public {
        vm.expectRevert(GuardianHook.InvalidCallbackSender.selector);
        guardianHook.reactivePause(address(this), poolId, "NO_OP_ALERT");
    }

    function testReactivePauseRejectsUnexpectedReactiveSource() public {
        vm.prank(CALLBACK_SENDER);
        vm.expectRevert(GuardianHook.InvalidReactiveSource.selector);
        guardianHook.reactivePause(address(0xDEAD), poolId, "NO_OP_ALERT");
    }

    function testReactivePauseFlowPausesPool() public {
        SwapParams memory params =
            SwapParams({ zeroForOne: true, amountSpecified: 10, sqrtPriceLimitX96: 0 });
        BalanceDelta delta = toBalanceDelta(0, 0);

        poolManager.callBeforeSwap(guardianHook, address(this), poolKey, params);
        poolManager.setPoolState(poolId, uint160(1000), 10, 500);
        poolManager.callAfterSwap(guardianHook, address(this), poolKey, params, delta);

        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: ORIGIN_CHAIN_ID,
            _contract: address(guardianHook),
            topic_0: uint256(keccak256("EmergencyAlert(bytes32,string,uint256)")),
            topic_1: uint256(poolId),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode("NO_OP_ALERT", block.timestamp),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });

        reactiveVmContract.react(log);

        vm.prank(CALLBACK_SENDER);
        guardianHook.reactivePause(address(this), poolId, "NO_OP_ALERT");

        (, bool paused,,,,,, string memory lastAlertReason,) = guardianHook.getPoolState(poolId);
        assertTrue(paused);
        assertEq(lastAlertReason, "NO_OP_ALERT");
    }

    function testReactiveRnDeploymentSubscribesToEmergencyAlerts() public {
        MockReactiveService service = new MockReactiveService();
        ReactiveContract reactiveRnContract = new ReactiveContract(
            address(service),
            ORIGIN_CHAIN_ID,
            DESTINATION_CHAIN_ID,
            address(guardianHook),
            poolId,
            CALLBACK_GAS_LIMIT
        );

        MockReactiveService.Subscription memory sub = service.getLastSubscription();

        assertEq(sub.chainId, ORIGIN_CHAIN_ID);
        assertEq(sub.contractAddress, address(guardianHook));
        assertEq(sub.topic0, uint256(keccak256("EmergencyAlert(bytes32,string,uint256)")));
        assertEq(sub.topic1, uint256(poolId));
        assertEq(sub.topic2, service.expectedIgnore());
        assertEq(sub.topic3, service.expectedIgnore());
        assertEq(reactiveRnContract.originContract(), address(guardianHook));
        assertEq(reactiveRnContract.monitoredPoolId(), poolId);
    }
}
