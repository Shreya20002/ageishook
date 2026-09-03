// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console2.sol";

import "../src/GuardianHook.sol";
import "../src/GuardianHookFactory.sol";
import "../src/HookMiner.sol";

import { IPoolManager } from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import { IHooks } from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import { Currency } from "@uniswap/v4-core/src/types/Currency.sol";
import { PoolKey } from "@uniswap/v4-core/src/types/PoolKey.sol";
import { PoolId, PoolIdLibrary } from "@uniswap/v4-core/src/types/PoolId.sol";
import { ModifyLiquidityParams } from "@uniswap/v4-core/src/types/PoolOperation.sol";
import { PoolModifyLiquidityTest } from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import { PoolSwapTest } from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import { StateLibrary } from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import { TestERC20 } from "@uniswap/v4-core/src/test/TestERC20.sol";

/// Deploys AegisHook against the CANONICAL Uniswap v4 PoolManager on Ethereum Sepolia.
///
/// Unlike script/Deploy.s.sol this script initializes the pool and seeds liquidity, so the
/// hook has real state to guard the moment it lands. The deployer is used as both `admin`
/// and `callbackSender` so a single key can drive the whole judge demo.
///
///   forge script script/DeploySepolia.s.sol:DeploySepoliaScript \
///     --rpc-url sepolia --account aegis-sepolia --sender <ADDR>          # simulate
///   ... add --broadcast --verify                                        # execute
contract DeploySepoliaScript is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // Canonical Uniswap v4 deployments on Ethereum Sepolia (11155111).
    // Source: https://developers.uniswap.org/contracts/v4/deployments
    address internal constant POOL_MANAGER = 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543;
    address internal constant POOL_SWAP_TEST = 0x9B6b46e2c869aa39918Db7f52f5557FE577B6eEe;
    address internal constant POOL_MODIFY_LIQUIDITY_TEST = 0x0C478023803a644c94c4CE1C1e7b9A087e411B0A;

    // Distinct from the deployer on purpose: reactivePause() must prove it checks the RVM id
    // rather than merely trusting whoever holds the callbackSender key.
    address internal constant TRUSTED_RVM_ID = 0x00000000000000000000000000000000000d00D0;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 internal constant MINT_AMOUNT = 1_000_000 ether;
    int256 internal constant LIQUIDITY_DELTA = 1e18;
    bytes internal constant ZERO_BYTES = new bytes(0);

    function run() external {
        require(block.chainid == 11155111, "DeploySepolia: not Ethereum Sepolia");

        vm.startBroadcast();
        address deployer = msg.sender;

        // 1. Two fresh test tokens, minted to the deployer.
        TestERC20 tokenA = new TestERC20(MINT_AMOUNT);
        TestERC20 tokenB = new TestERC20(MINT_AMOUNT);

        // 2. PoolKey requires currency0 < currency1; registerPool reverts InvalidCurrencyOrder.
        (address currency0, address currency1) = address(tokenA) < address(tokenB)
            ? (address(tokenA), address(tokenB))
            : (address(tokenB), address(tokenA));

        // 3-4. The factory is the CREATE2 deployer, so the salt can only be mined once the
        // factory address is known. This search runs in the script's local EVM, not on-chain.
        GuardianHookFactory hookFactory = new GuardianHookFactory();
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(GuardianHook).creationCode, abi.encode(POOL_MANAGER, deployer, deployer)
            )
        );
        (bytes32 salt, address predictedHook) =
            HookMiner.find(address(hookFactory), initCodeHash, 0, 200000);

        // 5. Deploying to a non-mined address reverts in the hook constructor.
        GuardianHook guardianHook = hookFactory.deploy(POOL_MANAGER, deployer, deployer, salt);
        require(address(guardianHook) == predictedHook, "DeploySepolia: hook address mismatch");

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(guardianHook))
        });
        bytes32 poolId = PoolId.unwrap(key.toId());

        // 6. Must precede registerPool, or the hook snapshots (0,0,0) off an empty pool.
        IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);

        // 7. beforeSwap carries a registeredPool modifier: until this runs, every swap reverts.
        guardianHook.registerPool(key);

        // 8. Seed liquidity. beforeAddLiquidity is not an enabled permission, so this does not
        // touch the hook.
        TestERC20(currency0).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        TestERC20(currency1).approve(POOL_MODIFY_LIQUIDITY_TEST, type(uint256).max);
        PoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_TEST).modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: LIQUIDITY_DELTA,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );

        // 9. Pre-approve the swap router so the demo script needs no setup transactions.
        TestERC20(currency0).approve(POOL_SWAP_TEST, type(uint256).max);
        TestERC20(currency1).approve(POOL_SWAP_TEST, type(uint256).max);

        guardianHook.setTrustedReactiveRvmId(TRUSTED_RVM_ID);

        vm.stopBroadcast();

        (uint160 sqrtPriceX96, int24 tick,,) = IPoolManager(POOL_MANAGER).getSlot0(key.toId());
        uint128 liquidity = IPoolManager(POOL_MANAGER).getLiquidity(key.toId());

        console2.log("=== AegisHook deployed to Ethereum Sepolia ===");
        console2.log("deployer / admin / callbackSender:", deployer);
        console2.log("PoolManager (canonical):          ", POOL_MANAGER);
        console2.log("GuardianHookFactory:              ", address(hookFactory));
        console2.log("GuardianHook:                     ", address(guardianHook));
        console2.log("hook flag bits (must be 0xc0):    ", uint256(uint160(address(guardianHook)) & 0x3fff));
        console2.log("token0:                           ", currency0);
        console2.log("token1:                           ", currency1);
        console2.log("trustedReactiveRvmId:             ", TRUSTED_RVM_ID);
        console2.log("poolId:");
        console2.logBytes32(poolId);
        console2.log("--- live pool state ---");
        console2.log("sqrtPriceX96:", uint256(sqrtPriceX96));
        console2.log("tick:        ", int256(tick));
        console2.log("liquidity:   ", uint256(liquidity));

        console2.log("");
        console2.log("--- paste into .env.local ---");
        console2.log("NEXT_PUBLIC_GUARDIAN_HOOK_ADDRESS=%s", vm.toString(address(guardianHook)));
        console2.log("NEXT_PUBLIC_POOL_ID=%s", vm.toString(poolId));
        console2.log("");
        console2.log("--- paste into .env (for SepoliaDemo.s.sol) ---");
        console2.log("GUARDIAN_HOOK=%s", vm.toString(address(guardianHook)));
        console2.log("TOKEN0=%s", vm.toString(currency0));
        console2.log("TOKEN1=%s", vm.toString(currency1));
    }
}
