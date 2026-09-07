// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {FixedPoint96} from "infinity-core/src/pool-cl/libraries/FixedPoint96.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {TokenFixture} from "../helpers/TokenFixture.sol";
import {MockInfinityRouter} from "../mocks/MockInfinityRouter.sol";
import {IInfinityRouter} from "../../src/interfaces/IInfinityRouter.sol";
import {ICLRouterBase} from "../../src/pool-cl/interfaces/ICLRouterBase.sol";
import {PathKey} from "../../src/libraries/PathKey.sol";
import {Plan, Planner} from "../../src/libraries/Planner.sol";
import {Actions} from "../../src/libraries/Actions.sol";
import {ActionConstants} from "../../src/libraries/ActionConstants.sol";

/// @notice Exact output is all-or-nothing. A CL swap partial-fills when the pool runs out of liquidity
///         before the (hardcoded, global) price limit, so the router must revert `ExactOutputUnfilled`
///         rather than silently deliver less than the requested `amountOut`.
contract CLSwapRouterExactOutputUnfilledTest is TokenFixture, Test {
    IVault public vault;
    ICLPoolManager public poolManager;
    CLPoolManagerRouter public positionManager;
    MockInfinityRouter public router;

    /// @dev tickSpacing = 1, no hooks
    bytes32 constant PARAMETERS = bytes32(uint256(0x10000));

    /// @dev currency0/currency1 at price 100, liquidity in a 2-tick band only: ~0.05 currency0 and
    ///      ~5 currency1 of depth. Any larger exact-output request cannot fill.
    PoolKey public thinKey;
    /// @dev currency1/currency2 at price 1, ~25 of each currency: deep enough to fill the amounts here
    PoolKey public deepKey;

    Plan plan;

    function setUp() public {
        plan = Planner.init();
        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));

        initializeTokens();

        positionManager = new CLPoolManagerRouter(vault, poolManager);
        router = new MockInfinityRouter(vault, poolManager, IBinPoolManager(address(0)));
        for (uint256 i; i < 3; i++) {
            Currency currency = i == 0 ? currency0 : i == 1 ? currency1 : currency2;
            IERC20(Currency.unwrap(currency)).approve(address(positionManager), 100 ether);
            IERC20(Currency.unwrap(currency)).approve(address(router), 100 ether);
        }

        thinKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: PARAMETERS
        });
        poolManager.initialize(thinKey, uint160(10 * FixedPoint96.Q96));
        positionManager.modifyPosition(
            thinKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: 46053, tickUpper: 46055, liquidityDelta: 1e4 ether, salt: bytes32(0)
            }),
            new bytes(0)
        );

        deepKey = PoolKey({
            currency0: currency1,
            currency1: currency2,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: uint24(3000),
            parameters: PARAMETERS
        });
        poolManager.initialize(deepKey, uint160(1 * FixedPoint96.Q96));
        positionManager.modifyPosition(
            deepKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -5, tickUpper: 5, liquidityDelta: 1e5 ether, salt: bytes32(0)
            }),
            new bytes(0)
        );
    }

    function test_exactOutputSingle_revertsOnUnderfill() public {
        // the thin band holds ~5 currency1, so 10 ether out cannot fill
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(thinKey, true, 10 ether, type(uint128).max, new bytes(0));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);

        // the realized output is the pool's whole currency1 depth, ~5.02 ether
        vm.expectRevert(
            abi.encodeWithSelector(IInfinityRouter.ExactOutputUnfilled.selector, 10 ether, 5021655822772834910)
        );
        router.executeActions(data);
    }

    function test_exactOutputSingle_oneForZero_revertsOnUnderfill() public {
        // the thin band holds ~0.05 currency0, so 1 ether out cannot fill
        ICLRouterBase.CLSwapExactOutputSingleParams memory params =
            ICLRouterBase.CLSwapExactOutputSingleParams(thinKey, false, 1 ether, type(uint128).max, new bytes(0));

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency0, ActionConstants.MSG_SENDER);

        // the realized output is the pool's whole currency0 depth, ~0.0497 ether
        vm.expectRevert(
            abi.encodeWithSelector(IInfinityRouter.ExactOutputUnfilled.selector, 1 ether, 49775942348678953)
        );
        router.executeActions(data);
    }

    /// @notice currency2 -> currency1 -> currency0, where the hop delivering currency0 is the thin pool
    function test_exactOutput_revertsOnUnderfill_deliveringHop() public {
        PathKey[] memory path = new PathKey[](2);
        path[0] = _pathKey(currency2);
        path[1] = _pathKey(currency1);

        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency0, path, 1 ether, type(uint128).max);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency0, ActionConstants.MSG_SENDER);

        vm.expectRevert(
            abi.encodeWithSelector(IInfinityRouter.ExactOutputUnfilled.selector, 1 ether, 49775942348678953)
        );
        router.executeActions(data);
    }

    /// @notice An intermediate underfill cannot be left for settlement to catch when the path repeats a
    ///         currency. Route currency1 -> currency0 -> currency1 -> currency2: the middle hop (buying
    ///         currency1 out of the thin pool) underfills, and because currency1 is also the route's input
    ///         currency the shortfall merges into the input debt that SETTLE_ALL pays -- so no non-zero
    ///         delta survives to fail settlement, and the post-loop amountInMaximum check only ever sees
    ///         the last executed hop's own input. Only a per-hop assert catches this.
    function test_exactOutput_revertsOnIntermediateUnderfill_repeatedCurrency() public {
        PathKey[] memory path = new PathKey[](3);
        path[0] = _pathKey(currency1);
        path[1] = _pathKey(currency0);
        path[2] = _pathKey(currency1);

        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency2, path, 10 ether, 11 ether);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency1, currency2, ActionConstants.MSG_SENDER);

        // the MIDDLE hop is the one that reverts: it was asked for the 10.031 ether of currency1 that the
        // last hop consumed, and the thin pool can only deliver ~5.02
        vm.expectRevert(
            abi.encodeWithSelector(
                IInfinityRouter.ExactOutputUnfilled.selector, 10031093380150452359, 5021655822772834910
            )
        );
        router.executeActions(data);
    }

    /// @notice A request the pool can fill is unaffected by the new guard
    function test_exactOutputSingle_fullFillSucceeds() public {
        uint256 amountOut = 1 ether;
        uint256 balanceBefore = IERC20(Currency.unwrap(currency1)).balanceOf(address(this));

        ICLRouterBase.CLSwapExactOutputSingleParams memory params = ICLRouterBase.CLSwapExactOutputSingleParams(
            thinKey, true, uint128(amountOut), type(uint128).max, new bytes(0)
        );

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT_SINGLE, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency0, currency1, ActionConstants.MSG_SENDER);
        router.executeActions(data);

        assertEq(
            IERC20(Currency.unwrap(currency1)).balanceOf(address(this)) - balanceBefore,
            amountOut,
            "exact output delivered in full"
        );
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(router)), 0, "no input residual");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(router)), 0, "no output residual");
    }

    /// @notice currency2 -> currency1 -> currency0 for an amount both pools can fill. Both hops run
    ///         oneForZero, which is the direction the pre-existing multi-hop exactOutput tests never
    ///         exercise, so this pins down the input/output side selection for that branch.
    function test_exactOutput_multiHop_oneForZero_fullFillSucceeds() public {
        uint256 amountOut = 0.01 ether;
        uint256 inputBefore = IERC20(Currency.unwrap(currency2)).balanceOf(address(this));
        uint256 outputBefore = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        PathKey[] memory path = new PathKey[](2);
        path[0] = _pathKey(currency2);
        path[1] = _pathKey(currency1);

        ICLRouterBase.CLSwapExactOutputParams memory params =
            ICLRouterBase.CLSwapExactOutputParams(currency0, path, uint128(amountOut), type(uint128).max);

        plan = plan.add(Actions.CL_SWAP_EXACT_OUT, abi.encode(params));
        bytes memory data = plan.finalizeSwap(currency2, currency0, ActionConstants.MSG_SENDER);
        router.executeActions(data);

        uint256 paid = inputBefore - IERC20(Currency.unwrap(currency2)).balanceOf(address(this));
        assertEq(
            IERC20(Currency.unwrap(currency0)).balanceOf(address(this)) - outputBefore,
            amountOut,
            "exact output delivered in full"
        );
        assertEq(paid, 1006047259623890093);
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(router)), 0, "no output residual");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(router)), 0, "no intermediate residual");
        assertEq(IERC20(Currency.unwrap(currency2)).balanceOf(address(router)), 0, "no input residual");
    }

    function _pathKey(Currency intermediateCurrency) internal view returns (PathKey memory) {
        return PathKey({
            intermediateCurrency: intermediateCurrency,
            fee: uint24(3000),
            hooks: IHooks(address(0)),
            hookData: new bytes(0),
            poolManager: poolManager,
            parameters: PARAMETERS
        });
    }
}
