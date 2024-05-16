// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {CurrencySettleTake} from "v4-core/libraries/CurrencySettleTake.sol";
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
        // i.e. Create a debit of `amountEach` of each currency with the Pool Manager
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

        // Since we didn't go through the regular "modify liquidity" flow,
        // the PM just has a debit of `amountEach` of each currency from us
        // We can, in exchange, get back ERC-6909 claim tokens for `amountEach` of each currency
        // to create a credit of `amountEach` of each currency to us
        // that balances out the debit

        // We will store those claim tokens with the hook, so when swaps take place
        // liquidity from our CSMM can be used by minting/burning claim tokens the hook owns
        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true // true = mint claim tokens for the hook, equivalent to money we just deposited to the PM
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
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

        /**
            BalanceDelta is a packed value of (currency0Amount, currency1Amount)

            BeforeSwapDelta varies such that it is not sorted by token0 and token1
            Instead, it is sorted by "specifiedCurrency" and "unspecifiedCurrency"

            Specified Currency => The currency in which the user is specifying the amount they're swapping for
            Unspecified Currency => The other currency

            For example, in an ETH/USDC pool, there are 4 possible swap cases:

            1. ETH for USDC with Exact Input for Output (amountSpecified = negative value representing ETH)
            2. ETH for USDC with Exact Output for Input (amountSpecified = positive value representing USDC)
            3. USDC for ETH with Exact Input for Output (amountSpecified = negative value representing USDC)
            4. USDC for ETH with Exact Output for Input (amountSpecified = positive value representing ETH)

            In Case (1):
                -> the user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
                -> the unspecifiedCurrency is USDC

            In Case (2):
                -> the user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
                -> the unspecifiedCurrency is ETH

            In Case (3):
                -> the user is specifying their swap amount in terms of USDC, so the specifiedCurrency is USDC
                -> the unspecifiedCurrency is ETH

            In Case (4):
                -> the user is specifying their swap amount in terms of ETH, so the specifiedCurrency is ETH
                -> the unspecifiedCurrency is USDC
        
         */

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(
            int128(-params.amountSpecified), // So `specifiedAmount` = +100
            int128(params.amountSpecified) // Unspecified amount (output delta) = -100
        );

        if (params.zeroForOne) {
            // If user is selling Token 0 and buying Token 1

            // They will be sending Token 0 to the PM, creating a debit of Token 0 in the PM
            // We will take claim tokens for that Token 0 from the PM and keep it in the hook
            // and create an equivalent credit for that Token 0 since it is ours!
            key.currency0.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );

            // They will be receiving Token 1 from the PM, creating a credit of Token 1 in the PM
            // We will burn claim tokens for Token 1 from the hook so PM can pay the user
            // and create an equivalent debit for Token 1 since it is ours!
            key.currency1.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
        } else {
            key.currency0.settle(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
            key.currency1.take(
                poolManager,
                address(this),
                amountInOutPositive,
                true
            );
        }

        return (this.beforeSwap.selector, beforeSwapDelta);
    }
}
