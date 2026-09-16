// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title FullMath
 * @notice floor(a * b / d) with a full 512-bit intermediate, so the product may
 * exceed 2^256 without wrapping.
 * @dev Remco Bloemen's algorithm (MIT), the same one OpenZeppelin's Math.mulDiv
 * uses. Lifted out of RedemptionVault so it can be differential-tested against
 * that reference directly: this is the only hand-written assembly in the
 * project and every payout goes through it.
 */
library FullMath {
    error MathOverflow();
    error DivisionByZero();

    function mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            // 512-bit product as (hi, lo).
            uint256 lo = a * b;
            uint256 hi;
            assembly {
                let mm := mulmod(a, b, not(0))
                hi := sub(sub(mm, lo), lt(mm, lo))
            }

            // Fits in 256 bits: plain division is exact.
            if (hi == 0) {
                if (d == 0) revert DivisionByZero();
                return lo / d;
            }

            // The quotient must still fit in 256 bits.
            if (d <= hi) revert MathOverflow();

            // Subtract the remainder from the 512-bit product so it divides exactly.
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, d)
                hi := sub(hi, gt(remainder, lo))
                lo := sub(lo, remainder)
            }

            // Factor out powers of two, then invert the odd part mod 2^256.
            uint256 twos = d & (0 - d);
            assembly {
                d := div(d, twos)
                lo := div(lo, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            lo |= hi * twos;

            uint256 inv = (3 * d) ^ 2;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            inv *= 2 - d * inv;
            result = lo * inv;
        }
    }
}
