// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {CurveMath} from "../contracts/CurveMath.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract GraduationTest is ArcBase {
    using StateLibrary for IPoolManager;

    Trio official;
    Trio t;

    function setUp() public override {
        super.setUp();
        official = _official();
        t = _thirdParty(address(official.vault), official.vault.deadline());
        _later();
    }

    /// @dev One buy big enough to cross G: net = 0.97 * value >= 8000 -> value >= 8247.42.
    function _graduateWith(uint256 value) internal returns (uint256 out) {
        vm.prank(bob);
        out = t.curve.buy{value: value}(0, bob);
    }

    function _swapIn(Trio memory trio, address who, uint256 quoteIn) internal {
        // Read the key before pranking: an external call in the argument list would consume the prank.
        PoolKey memory key = trio.curve.poolKey();
        vm.prank(who);
        router.swap{value: quoteIn}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(quoteIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _swapOut(Trio memory trio, address who, uint256 tokensIn) internal {
        PoolKey memory key = trio.curve.poolKey();
        vm.startPrank(who);
        trio.token.approve(address(router), tokensIn);
        router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    function test_LaunchInitialisesThePool() public view {
        (uint160 price,,,) = manager.getSlot0(t.curve.poolId());
        assertEq(price, CurveMath.sqrtPriceX96(P, SUPPLY));
        assertTrue(t.curve.poolInitialized());
    }

    function test_GraduationSeedsPoolBurnsRemainderAndClosesCurve() public {
        uint256 supplyBefore = t.token.totalSupply();
        _graduateWith(9_000e18);

        assertTrue(t.curve.graduated());
        assertEq(t.curve.realQuote(), 0);
        assertEq(t.curve.tokenReserve(), 0);
        assertGt(t.curve.liquidity(), 0);
        assertGt(t.curve.quoteInPool(), 8_000e18); // 9000 * 0.97 = 8730 minus dust
        assertLt(t.curve.quoteInPool(), 8_730e18 + 1);
        assertGt(t.curve.burnedAtGraduation(), 0);
        assertEq(t.token.totalSupply(), supplyBefore - t.curve.burnedAtGraduation());
        // Nothing stranded: curve holds no tokens, and only claimable USDC.
        assertEq(t.token.balanceOf(address(t.curve)), 0);
        assertEq(address(t.curve).balance, t.curve.totalClaimable());
        // Pool price equals the curve's last price (the target computed before the liquidity shave).
        (uint160 price,,,) = manager.getSlot0(t.curve.poolId());
        assertEq(price, t.curve.graduationSqrtPriceX96());
        assertApproxEqRel(
            uint256(price),
            uint256(CurveMath.sqrtPriceX96(t.curve.quoteInPool(), t.curve.tokensInPool())),
            0.000001e18
        );
        assertGt(price, TickMath.MIN_SQRT_PRICE);

        vm.prank(bob);
        vm.expectRevert(BondingCurve.AlreadyGraduated.selector);
        t.curve.buy{value: 1e18}(0, bob);
        vm.prank(bob);
        vm.expectRevert(BondingCurve.AlreadyGraduated.selector);
        t.curve.sell(1, 0, bob);
    }

    function test_PoolIsTradableAfterGraduation() public {
        _graduateWith(9_000e18);
        uint256 tokensBefore = t.token.balanceOf(carol);
        _swapIn(t, carol, 100e18);
        assertGt(t.token.balanceOf(carol) - tokensBefore, 0);
    }

    function test_CollectFeesRoutesQuoteAndBurnsTokens() public {
        _graduateWith(9_000e18);
        // carol buys 100 USDC worth on Uniswap: 1% LP fee on the input = 1 USDC of currency0
        _swapIn(t, carol, 100e18);
        // then sells everything back: 1% fee on the token input
        uint256 got = t.token.balanceOf(carol);
        _swapOut(t, carol, got);

        uint256 vaultBefore = t.vault.reserve();
        uint256 issuerBefore = t.curve.claimable(issuer);
        uint256 officialBefore = official.vault.reserve();
        uint256 supplyBefore = t.token.totalSupply();
        (uint256 quoteFees, uint256 tokenFees) = t.curve.collectFees();
        assertApproxEqRel(quoteFees, 1e18, 0.001e18);
        assertApproxEqRel(tokenFees, got / 100, 0.001e18);
        // Pool share is the remainder after the platform and issuer slices, so rounding dust stays in the pool.
        assertEq(t.vault.reserve() - vaultBefore, quoteFees - quoteFees * 500 / 10_000 - quoteFees * 1_000 / 10_000);
        assertEq(t.curve.claimable(issuer) - issuerBefore, quoteFees * 1_000 / 10_000);
        assertEq(official.vault.reserve() - officialBefore, quoteFees * 500 / 10_000);
        assertEq(supplyBefore - t.token.totalSupply(), tokenFees);
        assertEq(t.curve.totalTokenFeesBurned(), tokenFees);
        assertEq(t.token.balanceOf(address(t.curve)), 0);
        assertEq(address(t.curve).balance, t.curve.totalClaimable());

        // Nothing new: a second collect is a no-op, not a revert.
        (uint256 q2, uint256 t2) = t.curve.collectFees();
        assertEq(q2, 0);
        assertEq(t2, 0);
    }

    function test_CollectBeforeGraduationReverts() public {
        vm.expectRevert(BondingCurve.NotGraduated.selector);
        t.curve.collectFees();
    }

    function test_GraduationSurvivesAPreInitialisedPool() public {
        // The factory deploys token, vault and curve in one transaction, so an
        // attacker cannot get between them; what they can do is predict the token
        // address (CREATE is deterministic) and initialise its pool at an absurd
        // price beforehand. Reproduce the resulting state: pool exists before
        // the curve claims it.
        LaunchToken tk = new LaunchToken("Rehearsal", "REHRSL");
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tk)),
            fee: 10_000,
            tickSpacing: 200,
            hooks: IHooks(address(0))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(600_000));

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
        f.curve.initializePool(); // does not revert: it sees the pool and skips initialize
        assertTrue(f.curve.poolInitialized());
        (uint160 squatted,,,) = manager.getSlot0(f.curve.poolId());
        assertEq(squatted, TickMath.getSqrtPriceAtTick(600_000));

        _later();
        vm.prank(bob);
        f.curve.buy{value: 9_000e18}(0, bob);
        assertTrue(f.curve.graduated());
        (uint160 price,,,) = manager.getSlot0(f.curve.poolId());
        // With no liquidity in the attacker's pool, the price swap lands exactly on target.
        assertEq(price, f.curve.graduationSqrtPriceX96());
        assertGt(f.curve.liquidity(), 0);
        assertEq(tk.balanceOf(address(f.curve)), 0);
    }

    function test_UnlockCallbackIsGated() public {
        vm.expectRevert(BondingCurve.NotPoolManager.selector);
        t.curve.unlockCallback("");
        vm.prank(POOL_MANAGER);
        vm.expectRevert(BondingCurve.NotUnlocking.selector);
        t.curve.unlockCallback("");
    }

    function test_GraduationAfterPoolDeadlineSendsDustToIssuer() public {
        vm.warp(t.vault.deadline());
        uint256 claimBefore = t.curve.claimable(issuer);
        _graduateWith(9_000e18);
        assertTrue(t.curve.graduated());
        assertGt(t.curve.claimable(issuer), claimBefore); // fee share + dust, none of it pushed to the closed vault
        assertEq(address(t.curve).balance, t.curve.totalClaimable());
    }
}
