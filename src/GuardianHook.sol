// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Hooks } from "@uniswap/v4-core/src/libraries/Hooks.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import { ModifyLiquidityParams, SwapParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";

contract GuardianHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;
    using BalanceDeltaLibrary for BalanceDelta;

    enum ActionType {
        None,
        Swap,
        LiquidityAdded,
        LiquidityRemoved,
        Sync
    }

    struct PoolConfig {
        bool registered;
        bool paused;
        bool entered;
        uint160 lastSqrtPriceX96;
        int24 lastTick;
        uint128 liquidity;
        ActionType lastAction;
        uint256 lastUpdatedAt;
        string lastAlertReason;
        uint256 lastAlertAt;
    }

    struct SwapCheckpoint {
        bool active;
        uint160 sqrtPriceX96;
        int24 tick;
        uint128 liquidity;
    }

    address public immutable admin;
    IPoolManager public immutable poolManager;
    address public immutable callbackSender;
    address public trustedReactiveRvmId;

    mapping(bytes32 => PoolConfig) private pools;
    mapping(bytes32 => SwapCheckpoint) private checkpoints;
    mapping(address => bool) public auditors;

    error Unauthorized();
    error NotPoolManager();
    error PoolAlreadyRegistered();
    error PoolNotRegistered();
    error PoolPaused();
    error InvalidSwap();
    error ReentrancyDetected();
    error InvalidCallbackSender();
    error InvalidReactiveSource();
    error NoActiveSwap();
    error InvalidHookAddress();
    error InvalidCurrencyOrder();

    event PoolRegistered(
        bytes32 indexed poolId,
        address indexed currency0,
        address indexed currency1,
        uint24 fee,
        int24 tickSpacing
    );
    event AuditorUpdated(address indexed auditor, bool allowed);
    event PoolPausedStateChanged(bytes32 indexed poolId, bool paused, string reason);
    event BeforeSwapValidated(
        bytes32 indexed poolId,
        address indexed sender,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity
    );
    event AfterSwapValidated(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0,
        int128 amount1,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        bool suspicious
    );
    event EmergencyAlert(bytes32 indexed poolId, string reason, uint256 detectedAt);
    event StateReported(
        bytes32 indexed poolId,
        uint160 sqrtPriceX96,
        int24 tick,
        uint128 liquidity,
        ActionType actionType
    );
    event TrustedReactiveRvmUpdated(address indexed reactiveRvmId);

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyCallbackSender() {
        if (msg.sender != callbackSender) revert InvalidCallbackSender();
        _;
    }

    modifier onlyAuditor() {
        if (!auditors[msg.sender] && msg.sender != admin) revert Unauthorized();
        _;
    }

    modifier registeredPool(bytes32 poolId) {
        if (!pools[poolId].registered) revert PoolNotRegistered();
        _;
    }

    modifier nonReentrant(bytes32 poolId) {
        PoolConfig storage config = pools[poolId];
        if (config.entered) revert ReentrancyDetected();
        config.entered = true;
        _;
        config.entered = false;
    }

    constructor(address poolManager_, address callbackSenderAddress, address adminAddress) {
        if (
            poolManager_ == address(0) || callbackSenderAddress == address(0)
                || adminAddress == address(0)
        ) {
            revert Unauthorized();
        }
        admin = adminAddress;
        poolManager = IPoolManager(poolManager_);
        callbackSender = callbackSenderAddress;
        IHooks(address(this)).validateHookPermissions(getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory permissions) {
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
    }

    function registerPool(PoolKey calldata key) external onlyAdmin returns (bytes32 poolId) {
        if (address(key.hooks) != address(this)) revert InvalidHookAddress();
        if (!(key.currency0 < key.currency1)) revert InvalidCurrencyOrder();

        poolId = PoolId.unwrap(key.toId());
        if (pools[poolId].registered) revert PoolAlreadyRegistered();

        pools[poolId].registered = true;
        _syncPoolState(poolId, ActionType.Sync);

        emit PoolRegistered(
            poolId,
            Currency.unwrap(key.currency0),
            Currency.unwrap(key.currency1),
            key.fee,
            key.tickSpacing
        );
    }

    function setAuditor(address auditor, bool allowed) external onlyAdmin {
        auditors[auditor] = allowed;
        emit AuditorUpdated(auditor, allowed);
    }

    function setTrustedReactiveRvmId(address reactiveRvmId) external onlyAdmin {
        if (reactiveRvmId == address(0)) revert Unauthorized();
        trustedReactiveRvmId = reactiveRvmId;
        emit TrustedReactiveRvmUpdated(reactiveRvmId);
    }

    function isSwapAllowed(bytes32 poolId, int256 amountSpecified)
        public
        view
        returns (bool allowed, string memory reason)
    {
        PoolConfig storage config = pools[poolId];

        if (!config.registered) return (false, "POOL_NOT_REGISTERED");
        if (config.paused) return (false, "POOL_PAUSED");
        if (amountSpecified == 0) return (false, "ZERO_AMOUNT_SPECIFIED");

        return (true, "SAFE");
    }

    function pausePool(bytes32 poolId, string calldata reason)
        external
        onlyAuditor
        registeredPool(poolId)
    {
        PoolConfig storage config = pools[poolId];
        config.paused = true;
        config.lastUpdatedAt = block.timestamp;

        emit PoolPausedStateChanged(poolId, true, reason);
    }

    function reactivePause(address reactiveRvmId, bytes32 poolId, string calldata reason)
        external
        onlyCallbackSender
        registeredPool(poolId)
    {
        PoolConfig storage config = pools[poolId];
        if (reactiveRvmId != trustedReactiveRvmId) revert InvalidReactiveSource();

        config.paused = true;
        config.lastAlertReason = reason;
        config.lastAlertAt = block.timestamp;
        config.lastUpdatedAt = block.timestamp;

        emit PoolPausedStateChanged(poolId, true, reason);
    }

    function unpausePool(bytes32 poolId) external onlyAdmin registeredPool(poolId) {
        PoolConfig storage config = pools[poolId];
        config.paused = false;
        config.lastUpdatedAt = block.timestamp;

        emit PoolPausedStateChanged(poolId, false, "ADMIN_RESET");
    }

    function resetPoolAlert(bytes32 poolId) external onlyAdmin registeredPool(poolId) {
        PoolConfig storage config = pools[poolId];
        config.lastAlertReason = "";
        config.lastAlertAt = 0;
        config.lastUpdatedAt = block.timestamp;
    }

    function syncPoolState(bytes32 poolId)
        external
        registeredPool(poolId)
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
    {
        return _syncPoolState(poolId, ActionType.Sync);
    }

    function getPoolState(bytes32 poolId)
        external
        view
        returns (
            bool registered,
            bool paused,
            uint160 lastSqrtPriceX96,
            int24 lastTick,
            uint128 liquidity,
            ActionType lastAction,
            uint256 lastUpdatedAt,
            string memory lastAlertReason,
            uint256 lastAlertAt
        )
    {
        PoolConfig storage config = pools[poolId];
        return (
            config.registered,
            config.paused,
            config.lastSqrtPriceX96,
            config.lastTick,
            config.liquidity,
            config.lastAction,
            config.lastUpdatedAt,
            config.lastAlertReason,
            config.lastAlertAt
        );
    }

    function getHookRiskScore(bytes32 poolId) external view returns (uint256) {
        PoolConfig storage config = pools[poolId];
        if (!config.registered) return 100;
        if (config.paused) return 95;

        uint256 score = 10;
        if (config.lastSqrtPriceX96 == 0 && config.liquidity == 0) score += 30;
        if (config.lastAction == ActionType.None) score += 10;
        if (block.timestamp > config.lastUpdatedAt + 1 days) score += 20;
        if (bytes(config.lastAlertReason).length != 0) score += 15;

        return score;
    }

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        registeredPool(PoolId.unwrap(key.toId()))
        nonReentrant(PoolId.unwrap(key.toId()))
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        PoolConfig storage config = pools[poolId];
        if (config.paused) revert PoolPaused();

        (bool allowed,) = isSwapAllowed(poolId, params.amountSpecified);
        if (!allowed) revert InvalidSwap();

        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) = _getPoolSnapshot(poolId);
        checkpoints[poolId] = SwapCheckpoint({
            active: true,
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            liquidity: liquidity
        });

        emit BeforeSwapValidated(
            poolId, sender, params.zeroForOne, params.amountSpecified, sqrtPriceX96, tick, liquidity
        );

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    )
        external
        override
        onlyPoolManager
        registeredPool(PoolId.unwrap(key.toId()))
        nonReentrant(PoolId.unwrap(key.toId()))
        returns (bytes4, int128)
    {
        bytes32 poolId = PoolId.unwrap(key.toId());
        SwapCheckpoint memory checkpoint = checkpoints[poolId];
        if (!checkpoint.active) revert NoActiveSwap();

        (uint160 sqrtPriceX96, int24 tick, uint128 liquidity) = _getPoolSnapshot(poolId);
        int128 amount0 = delta.amount0();
        int128 amount1 = delta.amount1();

        bool noOpDelta = amount0 == 0 && amount1 == 0;
        bool unchangedState = checkpoint.sqrtPriceX96 == sqrtPriceX96 && checkpoint.tick == tick
            && checkpoint.liquidity == liquidity;
        bool liquidityDropped = liquidity < checkpoint.liquidity;
        bool suspicious = noOpDelta || unchangedState || (liquidityDropped && noOpDelta);

        PoolConfig storage config = pools[poolId];
        config.lastSqrtPriceX96 = sqrtPriceX96;
        config.lastTick = tick;
        config.liquidity = liquidity;
        config.lastAction = ActionType.Swap;
        config.lastUpdatedAt = block.timestamp;

        delete checkpoints[poolId];

        emit StateReported(poolId, sqrtPriceX96, tick, liquidity, ActionType.Swap);
        emit AfterSwapValidated(
            poolId, sender, amount0, amount1, sqrtPriceX96, tick, liquidity, suspicious
        );

        if (suspicious) {
            config.lastAlertReason = "NO_OP_ALERT";
            config.lastAlertAt = block.timestamp;
            emit EmergencyAlert(poolId, "NO_OP_ALERT", block.timestamp);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        return IHooks.afterDonate.selector;
    }

    function _syncPoolState(bytes32 poolId, ActionType actionType)
        internal
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
    {
        (sqrtPriceX96, tick, liquidity) = _getPoolSnapshot(poolId);

        PoolConfig storage config = pools[poolId];
        config.lastSqrtPriceX96 = sqrtPriceX96;
        config.lastTick = tick;
        config.liquidity = liquidity;
        config.lastAction = actionType;
        config.lastUpdatedAt = block.timestamp;

        emit StateReported(poolId, sqrtPriceX96, tick, liquidity, actionType);
    }

    function _getPoolSnapshot(bytes32 poolId)
        internal
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity)
    {
        PoolId id = PoolId.wrap(poolId);
        (sqrtPriceX96, tick,,) = poolManager.getSlot0(id);
        liquidity = poolManager.getLiquidity(id);
    }
}
