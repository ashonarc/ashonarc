import { ethers } from "ethers";

const usdc = (wei) => ethers.formatEther(wei);
const tokens = (wei) => ethers.formatUnits(wei, 18);
const pct = (part, whole) => (whole === 0n ? 0 : Number((part * 1000000n) / whole) / 10000);

/**
 * Turns a raw LaunchpadLens.TokenView into something a page can render without
 * re-deriving anything. Every wei value is kept as a string alongside its
 * formatted form: a front end must never do arithmetic on the formatted number.
 */
export function decorate(v) {
  const now = Math.floor(Date.now() / 1000);
  const deadline = Number(v.deadline);
  const graduated = Number(v.phase) === 1;

  return {
    token: v.token,
    curve: v.curve,
    vault: v.vault,
    issuer: v.issuer,
    name: v.name,
    symbol: v.symbol,
    logo: v.logo,
    description: v.description,
    socials: v.socials,
    launchedAt: Number(v.launchedAt),

    // Where the market is
    phase: Number(v.phase),
    phaseName: graduated ? "graduated" : "curve",
    graduated,
    graduationProgressBps: Number(v.graduationProgressBps),
    graduationThresholdUsdc: usdc(v.graduationThreshold),
    virtualQuoteUsdc: usdc(v.virtualQuote),

    // Curve
    realQuoteWei: v.realQuote.toString(),
    realQuoteUsdc: usdc(v.realQuote),
    tokenReserve: tokens(v.tokenReserve),
    // USDC per whole token on the curve (0 once graduated: read poolPrice instead)
    spotPriceUsdc: usdc(v.spotPriceWad),
    feeBps: Number(v.feeBps),
    poolBps: Number(v.poolBps),
    issuerBps: Number(v.issuerBps),
    platformBps: Number(v.platformBps),
    issuerClaimableUsdc: usdc(v.issuerClaimable),
    totalFeesToPoolUsdc: usdc(v.totalFeesToPool),
    totalFeesToIssuerUsdc: usdc(v.totalFeesToIssuer),
    totalFeesToPlatformUsdc: usdc(v.totalFeesToPlatform),
    totalSnipeTaxUsdc: usdc(v.totalSnipeTax),

    // Redemption pool
    reserveWei: v.reserve.toString(),
    reserveUsdc: usdc(v.reserve),
    backingPerTokenWei: v.backingPerToken.toString(),
    backingPerTokenUsdc: usdc(v.backingPerToken),
    totalFundedUsdc: usdc(v.totalFunded),
    totalRedeemedUsdc: usdc(v.totalRedeemed),
    totalBurned: tokens(v.totalBurned),
    residualSwept: v.residualSwept,

    // Window
    deadline,
    deadlineIso: new Date(deadline * 1000).toISOString(),
    secondsLeft: Math.max(0, deadline - now),
    isOpen: v.isOpen,

    // Supply
    totalSupply: tokens(v.totalSupply),
    // Disclosure: tokens inside the locked Uniswap position can never be
    // redeemed, and the figure moves with every swap.
    lockedInPool: tokens(v.lockedInPool),
    lockedInPoolPct: pct(v.lockedInPool, v.totalSupply),
    burnedAtGraduation: tokens(v.burnedAtGraduation),
    totalTokenFeesBurned: tokens(v.totalTokenFeesBurned),

    // Uniswap pool
    poolId: v.poolId,
    quoteInPoolUsdc: usdc(v.quoteInPool),
    tokensInPool: tokens(v.tokensInPool),
    liquidity: v.liquidity.toString(),
    sqrtPriceX96: v.sqrtPriceX96.toString(),
    poolPriceUsdc: usdc(v.poolPriceWad),

    launchFeeUsdc: usdc(v.launchFee),
  };
}
