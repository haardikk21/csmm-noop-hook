// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/types/BeforeSwapDelta.sol";
import {BaseHook} from "./forks/BaseHook.sol";

// A CSMM is a pricing curve that follows the invariant `x + y = k`
// instead of the invariant `x * y = k`

// This is theoretically the ideal curve for a stablecoin or pegged pairs (stETH/ETH)
// In practice, we don't usually see this in prod since depegs can happen and we dont want exact equal amounts
// But is a nice little NoOp hook example

contract CSMM is BaseHook {
    using CurrencySettleTake for Currency;

    error AddLiquidityThroughHook();

    struct CallbackData {
        uint256 amountEach;
        Currency currency0;
        Currency currency1;
        address sender;
    }

    constructor(IPoolManager poolManager) BaseHook(poolManager) {}

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Don't allow adding liquidity normally
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override how swaps are done
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Allow beforeSwap to return a custom delta
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // Disable adding liquidity through the PM
    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    // Custom add liquidity function
    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
            abi.encode(
                CallbackData(
                    amountEach,
                    key.currency0,
                    key.currency1,
                    msg.sender
                )
            )
        );
    }

    function unlockCallback(
        bytes calldata data
    ) external override poolManagerOnly returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));

        // Settle `amountEach` of each currency from the sender
        callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false // `burn` = `false` i.e. we're actually transferring tokens, not burning ERC-6909 Claim Tokens
        );
        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        // Mint some sort of LP Token to the sender
        // We can either implement our own LP Tokens (ERC-20, for example, for each pool)
        // Or, we can use the ERC-6909 Claim Tokens as a way to represent LP Tokens
        // (i.e. the `amountEach` of each currency is the amount of Claim Tokens minted)
        // We will mint ERC-6909 Claim Tokens for `amountEach` of each currency
        callbackData.currency0.take(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            true // true = mint claim tokens, not actually transfer these tokens around
        );
        callbackData.currency1.take(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            true
        );

        return "";
    }

    // Swapping
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override returns (bytes4, BeforeSwapDelta) {
        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        BeforeSwapDelta beforeSwapDelta;

        if (params.amountSpecified < 0) {
            // Exact Input
            // For example, if user wants to swap 100 Token 0
            // They specify (-100) as the amountSpecified
            // We want to take 100 Token 0 from the sender and net it such that PM swapAmount = 0
            beforeSwapDelta = toBeforeSwapDelta(
                int128(-params.amountSpecified), // So `specifiedAmount` = +100
                int128(params.amountSpecified) // Unspecified amount (output delta) = -100
            );
        } else {
            // Exact Output
            // User specifies +100 Token 1 as the amountSpecified (zeroForOne)
            // We want to take -100 Token 1 from the sender
            // We want to send +100 Token 1 to the sender
            beforeSwapDelta = toBeforeSwapDelta(
                int128(-params.amountSpecified),
                int128(params.amountSpecified)
            );
        }

        // if (params.zeroForOne) {
        //     key.currency0.take(
        //         poolManager,
        //         address(this),
        //         amountInOutPositive,
        //         false
        //     );
        //     key.currency1.settle(
        //         poolManager,
        //         address(this),
        //         amountInOutPositive,
        //         false
        //     );
        // } else {
        //     key.currency0.settle(
        //         poolManager,
        //         address(this),
        //         amountInOutPositive,
        //         false
        //     );
        //     key.currency1.take(
        //         poolManager,
        //         address(this),
        //         amountInOutPositive,
        //         false
        //     );
        // }

        return (this.beforeSwap.selector, beforeSwapDelta);
    }
}
