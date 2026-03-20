export const guardianHookAbi = [
  "function admin() view returns (address)",
  "function poolManager() view returns (address)",
  "function callbackSender() view returns (address)",
  "function trustedReactiveRvmId() view returns (address)",
  "function getPoolState(bytes32 poolId) view returns (bool registered, bool paused, uint160 lastSqrtPriceX96, int24 lastTick, uint128 liquidity, uint8 lastAction, uint256 lastUpdatedAt, string lastAlertReason, uint256 lastAlertAt)",
  "function getHookRiskScore(bytes32 poolId) view returns (uint256)",
  "function isSwapAllowed(bytes32 poolId, int256 amountSpecified) view returns (bool allowed, string reason)"
];
