// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {CurveMath} from "../contracts/CurveMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Graduation under hostile pool states: unclaimed, squatted, and stuffed with foreign liquidity.
contract GraduationAdversarialTest is ArcBase {
    using StateLibrary for IPoolManager;

    Trio official;
    Trio t;

    function setUp() public override {
        super.setUp();
        official = _official();
        t = _thirdParty(address(official.vault), official.vault.deadline());
        _later();
    }

    /// @dev A curve whose pool was never claimed still graduates: it initialises the pool itself.
    function test_GraduationInitialisesAnUnclaimedPool() public {
        LaunchToken tk = new LaunchToken("Rehearsal", "REHRSL");
        RedemptionVault v = new RedemptionVault(address(tk), block.timestamp + 30 days, issuer);
        BondingCurve c = new BondingCurve(
            BondingCurve.Config({
                factory: address(this),
                token: address(tk),
                vault: address(v),
                issuer: issuer,
                officialVault: address(official.vault),
                officialDeadline: official.vault.deadline(),
                platformSink: address(sink),
                poolManager: POOL_MANAGER,
                virtualQuote: P,
                graduationThreshold: G,
                poolBps: 8_500,
                issuerBps: 1_000,
                platformBps: 500
            })
        );
        tk.transfer(address(c), SUPPLY);
        // deliberately no initializePool()
        _later();
        vm.prank(bob);
        c.buy{value: 9_000e18}(0, bob);
        assertTrue(c.graduated());
        (uint160 price,,,) = manager.getSlot0(c.poolId());
        assertEq(price, c.graduationSqrtPriceX96());
        assertGt(c.liquidity(), 0);
    }

    function _addAttackerLiquidity(Trio memory trio, uint160 atSqrtPrice, uint256 quote, uint256 tokens) internal {
        PoolModifyLiquidityTest lp = new PoolModifyLiquidityTest(manager);
        uint128 liq = CurveMath.fullRangeLiquidity(
            atSqrtPrice, TickMath.getSqrtPriceAtTick(-887200), TickMath.getSqrtPriceAtTick(887200), quote, tokens
        );
        liq -= uint128(liq / 1_000 + 1);
        PoolKey memory key = trio.curve.poolKey();
        vm.startPrank(carol);
        trio.token.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity{value: quote}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887200,
                tickUpper: 887200,
                liquidityDelta: int256(uint256(liq)),
                salt: 0
            }),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Someone parks liquidity in the claimed pool at the launch price. At
    /// graduation the pool price is above ours, the budget swap pays USDC into
    /// their position, and the deposit lands at whatever price that reached.
    function test_GraduationWithForeignLiquidityAboveTarget() public {
        vm.prank(carol);
        t.curve.buy{value: 3_000e18}(0, carol);
        (uint160 launchPrice,,,) = manager.getSlot0(t.curve.poolId());
        _addAttackerLiquidity(t, launchPrice, 500e18, 100_000_000e18);

        vm.prank(bob);
        t.curve.buy{value: 9_000e18}(0, bob);
        assertTrue(t.curve.graduated());
        assertGt(t.curve.liquidity(), 0);
        assertEq(t.token.balanceOf(address(t.curve)), 0);
        assertEq(address(t.curve).balance, t.curve.totalClaimable());
        (uint160 price,,,) = manager.getSlot0(t.curve.poolId());
        assertEq(price, t.curve.graduationSqrtPriceX96());
        assertLt(price, launchPrice); // moved towards ours, even if it stopped short
    }

    /// @dev The mirror image: pool squatted and stuffed below our price, so the
    /// budget swap pays tokens instead.
    function test_GraduationWithForeignLiquidityBelowTarget() public {
        LaunchToken tk = new LaunchToken("Rehearsal", "REHRSL");
        uint160 low = TickMath.getSqrtPriceAtTick(90_000);
        manager.initialize(
            PoolKey({
                currency0: Currency.wrap(address(0)),
                currency1: Currency.wrap(address(tk)),
                fee: 10_000,
                tickSpacing: 200,
                hooks: IHooks(address(0))
            }),
            low
        );
        Trio memory f;
        f.token = tk;
        f.vault = new RedemptionVault(address(tk), block.timestamp + 30 days, issuer);
        f.curve = new BondingCurve(
            BondingCurve.Config({
                factory: address(this),
                token: address(tk),
                vault: address(f.vault),
                issuer: issuer,
                officialVault: address(official.vault),
                officialDeadline: official.vault.deadline(),
                platformSink: address(sink),
                poolManager: POOL_MANAGER,
                virtualQuote: P,
                graduationThreshold: G,
                poolBps: 8_500,
                issuerBps: 1_000,
                platformBps: 500
            })
        );
        tk.transfer(address(f.curve), SUPPLY);
        f.curve.initializePool();
        _later();
        vm.prank(carol);
        f.curve.buy{value: 3_000e18}(0, carol);
        _addAttackerLiquidity(f, low, 100e18, 810_000e18);

        vm.prank(bob);
        f.curve.buy{value: 9_000e18}(0, bob);
        assertTrue(f.curve.graduated());
        assertGt(f.curve.liquidity(), 0);
        assertEq(tk.balanceOf(address(f.curve)), 0);
        assertEq(address(f.curve).balance, f.curve.totalClaimable());
        (uint160 price,,,) = manager.getSlot0(f.curve.poolId());
        assertEq(price, f.curve.graduationSqrtPriceX96());
        assertGt(price, low);
    }
}
