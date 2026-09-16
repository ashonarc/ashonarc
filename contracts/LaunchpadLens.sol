// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {LaunchFactory} from "./LaunchFactory.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {RedemptionVault} from "./RedemptionVault.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {FullMath} from "./FullMath.sol";

/**
 * @title LaunchpadLens
 * @notice Everything a token page needs, in one call. Holds nothing, can move
 * nothing; it exists so the contracts that do hold funds can stay small.
 */
contract LaunchpadLens {
    using StateLibrary for IPoolManager;

    error UnknownToken();

    struct TokenView {
        address token;
        address curve;
        address vault;
        address issuer;
        string name;
        string symbol;
        string logo;
        string description;
        string socials;
        uint256 totalSupply;
        uint8 phase; // 0 curve, 1 graduated
        uint256 launchedAt;
        // curve
        uint256 realQuote;
        uint256 tokenReserve;
        uint256 virtualQuote;
        uint256 graduationThreshold;
        uint256 graduationProgressBps;
        uint256 spotPriceWad;
        uint256 feeBps;
        uint16 poolBps;
        uint16 issuerBps;
        uint16 platformBps;
        uint256 issuerClaimable;
        uint256 totalFeesToPool;
        uint256 totalFeesToIssuer;
        uint256 totalFeesToPlatform;
        uint256 totalSnipeTax;
        // vault
        uint256 reserve;
        uint256 backingPerToken;
        uint256 deadline;
        bool isOpen;
        uint256 totalFunded;
        uint256 totalRedeemed;
        uint256 totalBurned;
        bool residualSwept;
        // pool
        bytes32 poolId;
        uint256 quoteInPool;
        uint256 tokensInPool;
        uint256 burnedAtGraduation;
        uint128 liquidity;
        uint160 sqrtPriceX96;
        uint256 poolPriceWad;
        /// @dev Tokens inside the locked position right now: can never be
        /// redeemed, and moves with every swap. A page must say both things.
        uint256 lockedInPool;
        uint256 totalTokenFeesBurned;
        uint256 launchFee;
    }

    LaunchFactory public immutable factory;
    IPoolManager public immutable poolManager;

    constructor(address factory_) {
        factory = LaunchFactory(factory_);
        poolManager = LaunchFactory(factory_).poolManager();
    }

    function tokenView(address token) public view returns (TokenView memory v) {
        BondingCurve c = _curve(token);
        RedemptionVault r = RedemptionVault(payable(factory.vaultOf(token)));
        _fillIdentity(v, token, c);
        _fillCurve(v, c);
        _fillVault(v, r);
        _fillPool(v, c);
    }

    function tokenViews(uint256 start, uint256 count) external view returns (TokenView[] memory out) {
        uint256 total = factory.launchCount();
        if (start >= total) return new TokenView[](0);
        // `start + count` overflows on the natural "give me everything" call.
        uint256 end = count > total - start ? total : start + count;
        out = new TokenView[](end - start);
        for (uint256 i = start; i < end; i++) {
            out[i - start] = tokenView(factory.launchedTokens(i));
        }
    }

    function quoteBuy(address token, uint256 quoteIn, address recipient)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 tax)
    {
        return _curve(token).quoteBuy(quoteIn, recipient);
    }

    function quoteSell(address token, uint256 tokensIn) external view returns (uint256 quoteOut, uint256 fee) {
        return _curve(token).quoteSell(tokensIn);
    }

    function previewRedeem(address token, uint256 q) external view returns (uint256) {
        address vaultAddr = factory.vaultOf(token);
        if (vaultAddr == address(0)) revert UnknownToken();
        return RedemptionVault(payable(vaultAddr)).previewRedeem(q);
    }

    function _curve(address token) private view returns (BondingCurve) {
        address curveAddr = factory.curveOf(token);
        if (curveAddr == address(0)) revert UnknownToken();
        return BondingCurve(payable(curveAddr));
    }

    function _fillIdentity(TokenView memory v, address token, BondingCurve c) private view {
        LaunchToken t = LaunchToken(token);
        LaunchFactory.Metadata memory m = factory.metadataOf(token);
        v.token = token;
        v.curve = address(c);
        v.vault = address(c.vault());
        v.issuer = c.issuer();
        v.name = t.name();
        v.symbol = t.symbol();
        v.logo = m.logo;
        v.description = m.description;
        v.socials = m.socials;
        v.totalSupply = t.totalSupply();
        v.phase = c.graduated() ? 1 : 0;
        v.launchedAt = c.launchedAt();
        v.launchFee = factory.launchFee();
    }

    function _fillCurve(TokenView memory v, BondingCurve c) private view {
        v.realQuote = c.realQuote();
        v.tokenReserve = c.tokenReserve();
        v.virtualQuote = c.virtualQuote();
        v.graduationThreshold = c.graduationThreshold();
        v.graduationProgressBps = c.graduationProgressBps();
        v.spotPriceWad = c.spotPriceWad();
        v.feeBps = c.FEE_BPS();
        v.poolBps = c.poolBps();
        v.issuerBps = c.issuerBps();
        v.platformBps = c.platformBps();
        v.issuerClaimable = c.claimable(v.issuer);
        v.totalFeesToPool = c.totalFeesToPool();
        v.totalFeesToIssuer = c.totalFeesToIssuer();
        v.totalFeesToPlatform = c.totalFeesToPlatform();
        v.totalSnipeTax = c.totalSnipeTax();
    }

    function _fillVault(TokenView memory v, RedemptionVault r) private view {
        v.reserve = r.reserve();
        v.backingPerToken = r.backingPerToken();
        v.deadline = r.deadline();
        v.isOpen = r.isOpen();
        v.totalFunded = r.totalFunded();
        v.totalRedeemed = r.totalRedeemed();
        v.totalBurned = r.totalBurned();
        v.residualSwept = r.residualSwept();
    }

    function _fillPool(TokenView memory v, BondingCurve c) private view {
        PoolId id = c.poolId();
        v.poolId = PoolId.unwrap(id);
        v.quoteInPool = c.quoteInPool();
        v.tokensInPool = c.tokensInPool();
        v.burnedAtGraduation = c.burnedAtGraduation();
        v.liquidity = c.liquidity();
        v.totalTokenFeesBurned = c.totalTokenFeesBurned();
        if (v.phase == 1) {
            (v.sqrtPriceX96,,,) = poolManager.getSlot0(id);
            v.poolPriceWad = _quotePerTokenWad(v.sqrtPriceX96);
            v.lockedInPool = _tokensInPosition(v.sqrtPriceX96, v.liquidity);
        }
    }

    /// @dev sqrtPrice is sqrt(token per USDC) * 2^96; invert to USDC per token, 1e18-scaled.
    function _quotePerTokenWad(uint160 sqrtPriceX96) private pure returns (uint256) {
        if (sqrtPriceX96 == 0) return 0;
        uint256 priceX192 = uint256(sqrtPriceX96) * sqrtPriceX96; // token per USDC, Q192
        return FullMath.mulDiv(2 ** 96, 2 ** 96 * 1e18, priceX192);
    }

    /// @dev Token side of a full-range position at the current price.
    function _tokensInPosition(uint160 sqrtPriceX96, uint128 liq) private pure returns (uint256) {
        if (liq == 0 || sqrtPriceX96 == 0) return 0;
        uint160 sqrtA = TickMath.getSqrtPriceAtTick(-887200);
        uint160 sqrtB = TickMath.getSqrtPriceAtTick(887200);
        if (sqrtPriceX96 <= sqrtA) return 0;
        if (sqrtPriceX96 >= sqrtB) return SqrtPriceMath.getAmount1Delta(sqrtA, sqrtB, liq, false);
        return SqrtPriceMath.getAmount1Delta(sqrtA, sqrtPriceX96, liq, false);
    }
}
