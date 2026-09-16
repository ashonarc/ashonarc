// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CurveMath} from "../contracts/CurveMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

contract CurveMathTest is Test {
    uint256 constant P = 5_000e18;
    uint256 constant T0 = 1_000_000_000e18;
    uint256 constant K = P * T0;

    function test_CeilDiv() public pure {
        assertEq(CurveMath.ceilDiv(0, 7), 0);
        assertEq(CurveMath.ceilDiv(7, 7), 1);
        assertEq(CurveMath.ceilDiv(8, 7), 2);
    }

    function test_FirstBuyMatchesHandCalculation() public pure {
        // net 1000 USDC into P=5000, T0=1e9: newT = ceil(5e48 / 6000e18)
        (uint256 out, uint256 newT) = CurveMath.tokensOut(K, P, T0, 1_000e18);
        assertEq(newT, 833_333_333_333_333_333_333_333_334);
        assertEq(out, T0 - newT);
    }

    function test_SellBackReturnsNoMoreThanPaid() public pure {
        (uint256 out, uint256 newT) = CurveMath.tokensOut(K, P, T0, 1_000e18);
        (uint256 gross, uint256 backT) = CurveMath.quoteOut(K, P + 1_000e18, newT, out);
        assertEq(backT, T0);
        assertLe(gross, 1_000e18);
        assertGe(gross, 1_000e18 - 1e6); // only rounding is lost
    }

    function test_SnipeTaxTable() public pure {
        assertEq(CurveMath.snipeTaxBps(0, 3, 9_900), 9_900);
        assertEq(CurveMath.snipeTaxBps(1, 3, 9_900), 6_600);
        assertEq(CurveMath.snipeTaxBps(2, 3, 9_900), 3_300);
        assertEq(CurveMath.snipeTaxBps(3, 3, 9_900), 0);
        assertEq(CurveMath.snipeTaxBps(300, 3, 9_900), 0);
    }

    function test_SqrtPriceIsInTickMathRange() public pure {
        // launch price: 1e9 tokens per 5000 USDC
        uint160 s = CurveMath.sqrtPriceX96(P, T0);
        assertGt(s, TickMath.MIN_SQRT_PRICE);
        assertLt(s, TickMath.MAX_SQRT_PRICE);
        // graduation price: 236.7M tokens per 8000 USDC
        uint160 g = CurveMath.sqrtPriceX96(8_000e18, 236_686_390e18);
        assertGt(g, TickMath.MIN_SQRT_PRICE);
        assertLt(g, TickMath.MAX_SQRT_PRICE);
        assertLt(g, s); // fewer tokens per USDC after graduation
    }

    function test_FullRangeLiquidityConsumesBothSides() public pure {
        uint256 a0 = 8_000e18;
        uint256 a1 = 236_686_390e18;
        uint160 sp = CurveMath.sqrtPriceX96(a0, a1);
        uint160 sa = TickMath.getSqrtPriceAtTick(-887200);
        uint160 sb = TickMath.getSqrtPriceAtTick(887200);
        uint128 l = CurveMath.fullRangeLiquidity(sp, sa, sb, a0, a1);
        assertGt(l, 0);
        // L ~ sqrt(a0 * a1) ~ 1.375e24
        assertApproxEqRel(uint256(l), 1_375_000_000e15, 0.01e18);
    }

    function testFuzz_BuyThenSellNeverGainsAndKeepsInvariant(uint96 q1, uint96 q2) public pure {
        uint256 R;
        uint256 T = T0;
        uint256 in1 = uint256(q1) % 100_000e18 + 1;
        (uint256 out1, uint256 t1) = CurveMath.tokensOut(K, P + R, T, in1);
        R += in1;
        T = t1;
        assertGe((P + R) * T, K);
        uint256 in2 = uint256(q2) % 100_000e18 + 1;
        (uint256 out2, uint256 t2) = CurveMath.tokensOut(K, P + R, T, in2);
        R += in2;
        T = t2;
        assertGe((P + R) * T, K);
        (uint256 g, uint256 t3) = CurveMath.quoteOut(K, P + R, T, out1 + out2);
        assertLe(g, in1 + in2);
        assertLe(g, R);
        assertEq(t3, T0);
    }
}
