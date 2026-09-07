// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity ^0.8.0;

import {CurrencyLibrary, Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {ICLRouterBase} from "./interfaces/ICLRouterBase.sol";
import {IInfinityRouter} from "../interfaces/IInfinityRouter.sol";
import {PathKeyLibrary, PathKey} from "../libraries/PathKey.sol";
import {SafeCastTemp} from "../libraries/SafeCast.sol";
import {DeltaResolver} from "../base/DeltaResolver.sol";
import {ActionConstants} from "../libraries/ActionConstants.sol";

abstract contract CLRouterBase is ICLRouterBase, DeltaResolver {
    using SafeCastTemp for *;

    ICLPoolManager public immutable clPoolManager;

    constructor(ICLPoolManager _clPoolManager) {
        clPoolManager = _clPoolManager;
    }

    function _swapExactInputSingle(CLSwapExactInputSingleParams calldata params) internal {
        uint128 amountIn = params.amountIn;
        if (amountIn == ActionConstants.OPEN_DELTA) {
            amountIn =
                _getFullCredit(params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1).toUint128();
        }
        uint128 amountOut = _swapOutput(
            _swapExactPrivate(params.poolKey, params.zeroForOne, -int256(uint256(amountIn)), params.hookData),
            params.zeroForOne
        );
        if (amountOut < params.amountOutMinimum) {
            revert IInfinityRouter.TooLittleReceived(params.amountOutMinimum, amountOut);
        }
    }

    function _swapExactInput(CLSwapExactInputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountOut;
            Currency currencyIn = params.currencyIn;
            uint128 amountIn = params.amountIn;
            if (amountIn == ActionConstants.OPEN_DELTA) amountIn = _getFullCredit(currencyIn).toUint128();
            PathKey calldata pathKey;

            for (uint256 i = 0; i < pathLength; i++) {
                pathKey = params.path[i];
                (PoolKey memory poolKey, bool zeroForOne) = pathKey.getPoolAndSwapDirection(currencyIn);
                // The output delta will always be positive, except for when interacting with certain hook pools
                amountOut = _swapOutput(
                    _swapExactPrivate(poolKey, zeroForOne, -int256(uint256(amountIn)), pathKey.hookData), zeroForOne
                );

                amountIn = amountOut;
                currencyIn = pathKey.intermediateCurrency;
            }

            if (amountOut < params.amountOutMinimum) {
                revert IInfinityRouter.TooLittleReceived(params.amountOutMinimum, amountOut);
            }
        }
    }

    function _swapExactOutputSingle(CLSwapExactOutputSingleParams calldata params) internal {
        uint128 amountOut = params.amountOut;
        if (amountOut == ActionConstants.OPEN_DELTA) {
            amountOut =
                _getFullDebt(params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0).toUint128();
        }
        BalanceDelta delta =
            _swapExactPrivate(params.poolKey, params.zeroForOne, int256(uint256(amountOut)), params.hookData);
        // exact output is all-or-nothing: a pool can deliver less than requested if it runs out of
        // liquidity before the price limit. Reverting on a shortfall keeps "exact output" exact;
        // over-delivery (possible only via hook pools) is allowed.
        uint128 amountOutActual = _swapOutput(delta, params.zeroForOne);
        if (amountOutActual < amountOut) {
            revert IInfinityRouter.ExactOutputUnfilled(amountOut, amountOutActual);
        }
        uint128 amountIn = _swapInput(delta, params.zeroForOne);
        if (amountIn > params.amountInMaximum) {
            revert IInfinityRouter.TooMuchRequested(params.amountInMaximum, amountIn);
        }
    }

    function _swapExactOutput(CLSwapExactOutputParams calldata params) internal {
        unchecked {
            // Caching for gas savings
            uint256 pathLength = params.path.length;
            uint128 amountIn;
            uint128 amountOut = params.amountOut;
            Currency currencyOut = params.currencyOut;
            PathKey calldata pathKey;

            if (amountOut == ActionConstants.OPEN_DELTA) {
                amountOut = _getFullDebt(currencyOut).toUint128();
            }

            for (uint256 i = pathLength; i > 0; i--) {
                pathKey = params.path[i - 1];
                (PoolKey memory poolKey, bool oneForZero) = pathKey.getPoolAndSwapDirection(currencyOut);
                // The output delta will always be positive, except for when interacting with certain hook pools
                BalanceDelta delta =
                    _swapExactPrivate(poolKey, !oneForZero, int256(uint256(amountOut)), pathKey.hookData);
                uint128 amountOutActual = _swapOutput(delta, !oneForZero);
                // Every hop must fill. The vault nets one delta per currency across the whole unlock, so an
                // intermediate shortfall can be absorbed by same-currency credit and settle silently rather
                // than reverting -- and the amountInMaximum check below only ever sees the last hop's input.
                if (amountOutActual < amountOut) {
                    revert IInfinityRouter.ExactOutputUnfilled(amountOut, amountOutActual);
                }
                amountIn = _swapInput(delta, !oneForZero);

                amountOut = amountIn;
                currencyOut = pathKey.intermediateCurrency;
            }
            if (amountIn > params.amountInMaximum) {
                revert IInfinityRouter.TooMuchRequested(params.amountInMaximum, amountIn);
            }
        }
    }

    /// @return delta The balance delta of the swap, from the swapper's perspective
    function _swapExactPrivate(PoolKey memory poolKey, bool zeroForOne, int256 amountSpecified, bytes calldata hookData)
        private
        returns (BalanceDelta delta)
    {
        delta = clPoolManager.swap(
            poolKey,
            ICLPoolManager.SwapParams(
                zeroForOne, amountSpecified, zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            ),
            hookData
        );
    }

    /// @notice The positive input amount a swap consumed, derived from its balance delta.
    /// @dev The spent currency's delta is negative (owed to the pool), so negate it to a positive amount.
    function _swapInput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (uint256(-int256(zeroForOne ? delta.amount0() : delta.amount1()))).toUint128();
    }

    /// @notice The positive output amount a swap produced, derived from its balance delta. For an
    ///         exactOutput swap this is the REALIZED output, which can be less than the requested
    ///         amount when the pool lacks the liquidity to fill it before the price limit.
    function _swapOutput(BalanceDelta delta, bool zeroForOne) private pure returns (uint128) {
        return (zeroForOne ? delta.amount1() : delta.amount0()).toUint128();
    }
}
