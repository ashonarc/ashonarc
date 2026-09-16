// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "../contracts/FullMath.sol";

/**
 * @notice Differential tests for the only hand-written assembly in the project.
 * Every payout is floor(q * reserve / supply), so a wrong result here is a
 * wrong payout. Checked against OpenZeppelin's Math.mulDiv, and specifically
 * driven into the 512-bit path that the product-fits-in-256 shortcut skips.
 */
contract FullMathTest is Test {
    function test_MatchesReferenceOnSmallValues() public pure {
        for (uint256 a = 0; a < 40; a++) {
            for (uint256 b = 0; b < 40; b++) {
                for (uint256 d = 1; d < 40; d++) {
                    assertEq(FullMath.mulDiv(a, b, d), Math.mulDiv(a, b, d));
                }
            }
        }
    }

    /// @notice Fuzzed across the whole range, so most cases overflow 256 bits.
    function testFuzz_MatchesReference(uint256 a, uint256 b, uint256 d) public {
        d = bound(d, 1, type(uint256).max);
        (bool okRef, uint256 expected) = _tryReference(a, b, d);
        if (!okRef) {
            vm.expectRevert();
            this.callMulDiv(a, b, d);
            return;
        }
        assertEq(FullMath.mulDiv(a, b, d), expected);
    }

    /**
     * @notice Forces the 512-bit branch: with both factors above 2^128 the
     * product cannot fit in 256 bits, so the shortcut is unreachable.
     */
    function testFuzz_FiveTwelveBitPathMatchesReference(uint128 aHi, uint128 bHi, uint256 d) public view {
        uint256 a = (uint256(aHi) << 128) | 1;
        uint256 b = (uint256(bHi) << 128) | 1;
        vm.assume(a > type(uint128).max && b > type(uint128).max);
        // Denominator large enough that the quotient still fits.
        d = bound(d, uint256(type(uint128).max) + 1, type(uint256).max);
        (bool okRef, uint256 expected) = _tryReference(a, b, d);
        vm.assume(okRef);
        assertEq(FullMath.mulDiv(a, b, d), expected);
    }

    function test_KnownFiveTwelveBitCases() public pure {
        // 2^255 * 2 / 2^128 : product is exactly 2^256, well past the shortcut.
        assertEq(FullMath.mulDiv(2 ** 255, 2, 2 ** 128), Math.mulDiv(2 ** 255, 2, 2 ** 128));
        assertEq(FullMath.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max),
                 type(uint256).max);
        assertEq(FullMath.mulDiv(type(uint256).max, 1, type(uint256).max), 1);
        // Odd denominator exercises the modular-inverse branch. It has to be
        // large enough that the quotient still fits: 2^400 / 3 does not.
        assertEq(FullMath.mulDiv(2 ** 200, 2 ** 200, 3 * 2 ** 150),
                 Math.mulDiv(2 ** 200, 2 ** 200, 3 * 2 ** 150));
        // Power-of-two denominator exercises the twos-factoring branch.
        assertEq(FullMath.mulDiv(2 ** 200, 2 ** 200, 2 ** 150), Math.mulDiv(2 ** 200, 2 ** 200, 2 ** 150));
    }

    function test_DivisionByZeroReverts() public {
        vm.expectRevert(FullMath.DivisionByZero.selector);
        this.callMulDiv(1, 1, 0);
    }

    function test_QuotientOverflowReverts() public {
        // 2^255 * 2^255 / 1 cannot fit in 256 bits.
        vm.expectRevert(FullMath.MathOverflow.selector);
        this.callMulDiv(2 ** 255, 2 ** 255, 1);
    }

    function callMulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return FullMath.mulDiv(a, b, d);
    }

    function _tryReference(uint256 a, uint256 b, uint256 d) private view returns (bool ok, uint256 v) {
        try this.refMulDiv(a, b, d) returns (uint256 r) {
            return (true, r);
        } catch {
            return (false, 0);
        }
    }

    function refMulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return Math.mulDiv(a, b, d);
    }

    receive() external payable {}
}
