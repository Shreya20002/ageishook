export const guardianHookAbi = [
  "function admin() view returns (address)",
  "function poolManager() view returns (address)",
  "function callbackSender() view returns (address)",
  "function trustedReactiveRvmId() view returns (address)",
  "function getPoolState(bytes32 poolId) view returns (bool registered, bool paused, uint160 lastSqrtPriceX96, int24 lastTick, uint128 liquidity, uint8 lastAction, uint256 lastUpdatedAt, string lastAlertReason, uint256 lastAlertAt)",
  "function getHookRiskScore(bytes32 poolId) view returns (uint256)",
  "function isSwapAllowed(bytes32 poolId, int256 amountSpecified) view returns (bool allowed, string reason)",
  "event EmergencyAlert(bytes32 indexed poolId, string reason, uint256 detectedAt)",
  "event PoolPausedStateChanged(bytes32 indexed poolId, bool paused, string reason)"
];

export const frontendDemoAbi = [
  "function guardianHook() view returns (address)",
  "function poolId() view returns (bytes32)",
  "function predictedHook() view returns (address)",
  "function hookSalt() view returns (bytes32)",
  "function DEMO_RVM_ID() view returns (address)",
  "function healthySwapCount() view returns (uint256)",
  "function simulateHealthySwap()",
  "function triggerWarning()",
  "function triggerReactivePause(string reason)",
  "function resetDemo()",
  "event DemoReset(bytes32 indexed poolId)",
  "event DemoHealthySwap(bytes32 indexed poolId, uint160 sqrtPriceX96, int24 tick)",
  "event DemoWarningTriggered(bytes32 indexed poolId, string reason)",
  "event DemoReactivePause(bytes32 indexed poolId, string reason)"
];
