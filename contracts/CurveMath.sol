// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FullMath} from "./FullMath.sol";

/**
 * @title CurveMath
 * @notice Pure arithmetic for the bonding curve, kept apart from the contract
 * that holds funds so it can be tested against a Python model line by line.
 *
 * The curve is constant-product with a virtual quote reserve: (P + R) * T = k,
 * k = P * T0. Every division of k rounds up, so k can only grow and the real
 * reserve R can never go below what sells are owed.
 */
library CurveMath {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant Q96 = 2 ** 96;

    function ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice Tokens received for `netQuoteIn` (fees already removed).
    /// @param quote Current P + R.
    function tokensOut(uint256 k, uint256 quote, uint256 tokenReserve, uint256 netQuoteIn)
        internal
        pure
        returns (uint256 out, uint256 newTokenReserve)
    {
        newTokenReserve = ceilDiv(k, quote + netQuoteIn);
        out = tokenReserve > newTokenReserve ? tokenReserve - newTokenReserve : 0;
    }

    /// @notice Gross quote (before fees) for selling `tokensIn`.
    function quoteOut(uint256 k, uint256 quote, uint256 tokenReserve, uint256 tokensIn)
        internal
        pure
        returns (uint256 gross, uint256 newTokenReserve)
    {
        newTokenReserve = tokenReserve + tokensIn;
        uint256 newQuote = ceilDiv(k, newTokenReserve);
        gross = quote > newQuote ? quote - newQuote : 0;
    }

    /// @notice Linear decay from `maxBps` at launch to zero after `window` seconds.
    function snipeTaxBps(uint256 elapsed, uint256 window, uint256 maxBps) internal pure returns (uint256) {
        if (elapsed >= window) return 0;
        return maxBps * (window - elapsed) / window;
    }

    /// @notice sqrt(amount1 / amount0) * 2^96 -- the Uniswap price of currency1
    /// in currency0. Here currency0 is native USDC and currency1 the token.
    function sqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        uint256 ratioX192 = FullMath.mulDiv(amount1, 2 ** 192, amount0);
        return uint160(Math.sqrt(ratioX192));
    }

    /// @notice Liquidity a full-range position can mint from both amounts at
    /// price `sqrtP`; the smaller side binds. Same formulas as Uniswap's
    /// LiquidityAmounts.getLiquidityForAmounts.
    function fullRangeLiquidity(uint160 sqrtP, uint160 sqrtA, uint160 sqrtB, uint256 amount0, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        uint256 intermediate = FullMath.mulDiv(sqrtP, sqrtB, Q96);
        uint256 l0 = FullMath.mulDiv(amount0, intermediate, sqrtB - sqrtP);
        uint256 l1 = FullMath.mulDiv(amount1, Q96, sqrtP - sqrtA);
        uint256 l = l0 < l1 ? l0 : l1;
        require(l <= type(uint128).max, "liquidity overflow");
        return uint128(l);
    }
}
