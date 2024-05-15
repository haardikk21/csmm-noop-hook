# Custom Curve (CSMM) NoOp Hook

### NoOp Hooks Flow

NoOp hooks are hooks that can override the PM's own logic for operations - like swaps.

The way they work is that hooks like `beforeSwap` and `afterSwap` get the ability to return their own balance deltas. `beforeSwap` particularly has a special one - `BeforeSwapDelta` - which is slightly different from the normal `BalanceDelta`.

Based on the returned deltas, the actual operation supposed to be conducted by the PM may be modified.

For example, if a user wants to do an exact input swap for selling 1 Token A for Token B:

**Without NoOp Hooks**

- User calls `swap` on Swap Router
- Swap Router calls PM `swap`
- PM calls `beforeSwap` for whatever it needs to do
- PM conducts a swap on `pools[id].swap` with `amountSpecified = -1` and `zeroForOne = true`
- PM gets a `BalanceDelta` of `-1 Token A` and some positive `Token B` value
- PM calls `afterSwap` on the hook
- PM returns the `BalanceDelta` to the Swap Router
- Swap Router accounts for the `BalanceDelta` and trasnfers Token A from user to PM and Token B from PM to user

---

**With NoOp Hooks**

- User calls `swap` on Swap Router
- Swap Router calls PM `swap`
- PM calls `beforeSwap`
- `beforeSwap` can return a `BeforeSwapDelta` which specifies it has "consumed" the `-1 Token A` from the user, and has created a `+1 Token B` delta as well, leaving `0 Token A` to be swapped through the PM
- PM sees there are no tokens left to swap through its regular logic, so the regular `swap` operation is NoOp-ed
- PM calls `afterSwap`
- `afterSwap` can optionally return a different `BalanceDelta` further
- PM returns the final `BalanceDelta` to the Swap Router
- The final `BalanceDelta` is `-1 Token A` and `+1 Token B`
- Swap Router settles the final `BalanceDelta` and transfers Token A from user to PM and Token B from PM to user

It is possible for `beforeSwap` for example to only consume portion of the Token A - perhaps 0.5 Token A - and leave the remaining 0.5 Token A to go through the regular PM swap function. This is useful for example if the hook wants to charge "custom fees" for some services it is performing that it keeps for itself (not LP fee and not protocol fee).

### Setting Up

- Install `v4-core` instead of `v4-periphery`, as `v4-periphery` hasn't been updated to latest `v4-core` yet.

### Flow

The hook acts as a middleman between the User and the Pool Manager.

Liquidity Providers add liquidity through the hook, where the hook takes their tokens and adds that liquidity under its own control to the Pool Manager.

When swappers wish to swap on the CSMM, the hook is the one maintaining liquidity for the swap. This part is a little tricky - let's go through the flow.

Quick Revision of Terminology:

Remember that all terminology and conventions are designed from the perspective of the User.

- `take` => Receive a currency from the PoolManager i.e. user is "taking" money from PM
- `settle` => Sending a currency to the PoolManager i.e. user is "settling" debt to PM

The general flow for a swap goes as follows:

1. User calls Swap Router
2. Swap Router calls PM
3. PM calls hook
4. Hook returns
5. PM returns final BalanceDelta
6. Swap Router accounts for the final BalanceDelta

In our case, let's see what the flow looks like. First, for an LP:

1. LP wants to add 100 Token A and 100 Token B to the pool
2. LP calls `addLiquidity` on the hook contract directly (no routers, no PM involved)
3. Hook _does not_ go through "modifyLiquidity" on the PM - since that would be liquidity being added to the default pricing curve
4. Hook simply takes the user's money and sends it to PM (normal token transfer, not calling a function)
5. PM now has a debt to the hook of 100 Token A and 100 Token B
6. Hook "takes" the money back from the PM in the form of claim tokens
7. Hook keeps the claim tokens with itself, and accounts for the LP's share of the pool manually

Then, when a swapper comes by:

1. Swapper wants to swap 1 Token A for 1 Token B
2. Swapper calls `swap` on the Swap Router
3. Swap Router calls the PM `swap`
4. PM calls hook `beforeSwap`
5. To NoOp the PM's own `swap` function, `beforeSwap` must return a `BeforeSwapDelta` which negates the PMs swap. PMs swap is negated if there is no amount left to swap for the PM.
6. So, in this case, `beforeSwap` must say that it has consumed the 1 Token A provided as input, so there are 0 Tokens left to swap through the PM's own swap function - therefore NoOp-ing it
7. To actually handle the swap itself, remember the hook has claim tokens for all the liquidity with it.
8. The user, to sell Token A, must be sending 1 Token A to the PM. The hook will claim ownership of that 1 Token A by minting a claim token for it from the PM.
9. Also, the hook burns a claim token for B that it had, so the PM can use that Token B to pay the user
10. At the end of the PM's `swap` function, therefore, we have the following deltas created:

- User has a delta of -1 Token A to PM
- Hook has a delta of +1 Token A (claim token mint) from PM

- User has a delta of +1 Token B from PM
- Hook has a delta of -1 Token B (claim token burn) to PM

The sum total delta, therefore, is settled. Only thing left to do is move the underlying Token A from user to PM, and Token B from PM to user.

SwapRouter gets told to move `-1 Token A` from user to PM, and `+1 Token B` from PM to user. It does that, and the transaction is complete.

### Further Improvements

#### Removing Liquidity

The CSMM we built has no way for LPs to remove liquidity from the CSMM pool, because we don't track their percentage ownership of the pool reserves.

To do so, we can have our hook contract inherit from ERC-1155 or ERC-6909, and mint LP Tokens everytime they add liquidity.

A given LP's ownership of the pool is the amount of LP tokens they own divided by the total amount of LP tokens in circulation.

In a `removeLiquidity` function, we can burn some amount of their LP tokens as they wish, calculate their percentage ownership and equivalent amount of claim tokens we need to burn, burn those claim tokens we own from the pool manager to get the underlying tokens back, and send those underlying tokens to the LP.

#### Swap Fees

By NoOp-ing the PM swap function, and having a simple 1:1 exchange, our CSMM currently charges no fees.

Let's say you wish to charge some amount of fees in the input token currency. Let's say user is swapping 100 Token A as input token and we charge a flat 1% fee in the output token.

To do so:

- BeforeSwapDelta will consume the entire `specifiedAmount` of Token A (`-params.amountSpecified`)
- BeforeSwapDelta will create a positive delta for `unspecifiedAmount` of 99% of `params.amountSpecified`

- User will create a debit of 100 Token A in the PM
- Hook will create a credit of 100 Token A in the PM
- Hook will burn claim tokens for Token B to create a debit of 99% of 100 => 99 Token B in PM
- User will create a credit of 99 Token B in the PM

SwapRouter will move the tokens around - hook gets to keep 1 Token B. It can use this to partially provide yield for the LPs, and partially to keep for itself (you!).
