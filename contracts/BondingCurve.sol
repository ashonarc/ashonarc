// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {RedemptionVault} from "./RedemptionVault.sol";
import {CurveMath} from "./CurveMath.sol";
import {FullMath} from "./FullMath.sol";

/**
 * @title BondingCurve
 * @notice One per token. Constant-product pricing against a virtual reserve of
 * native USDC; a 3% fee on every trade is split the moment it is paid; when the
 * real reserve reaches the threshold the curve seeds a Uniswap V4 pool inside
 * that same transaction and holds the full-range position forever.
 *
 * Money only ever leaves this contract four ways: to a seller's receiver, to a
 * claimant of a pending share, to the Uniswap pool at graduation, and to our
 * own vault / sink contracts. Anyone who is not us gets paid only when they ask
 * -- Arc reverts value transfers to blocklisted addresses, and a push to such
 * an address on every trade would freeze the whole token.
 */
contract BondingCurve is IUnlockCallback {
    using StateLibrary for IPoolManager;

    error ZeroAddress();
    error ZeroAmount();
    error BadSplit();
    error AlreadyGraduated();
    error NotGraduated();
    error Slippage();
    error NothingToClaim();
    error Reentrancy();
    error NotPoolManager();
    error NotUnlocking();
    error TransferFailed();
    error UnknownCallback();

    struct Config {
        address factory;
        address token;
        address vault;
        address issuer;
        address officialVault; // zero for the official token itself
        uint256 officialDeadline;
        address platformSink;
        address poolManager;
        uint256 virtualQuote;
        uint256 graduationThreshold;
        uint16 poolBps;
        uint16 issuerBps;
        uint16 platformBps;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant FEE_BPS = 300;
    uint256 public constant SNIPE_TAX_SECONDS = 3;
    uint256 public constant SNIPE_TAX_MAX_BPS = 9_900;
    uint24 public constant POOL_FEE = 10_000; // 1%
    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887200;
    int24 public constant TICK_UPPER = 887200;
    /// @dev Share of the graduation deposit that may be spent moving a pool
    /// somebody else initialised back to our price.
    uint256 public constant PRICE_MOVE_BUDGET_BPS = 100;

    uint8 private constant CB_GRADUATE = 1;
    uint8 private constant CB_COLLECT = 2;

    LaunchToken public immutable token;
    RedemptionVault public immutable vault;
    address public immutable issuer;
    address public immutable officialVault;
    uint256 public immutable officialDeadline;
    address public immutable platformSink;
    IPoolManager public immutable poolManager;
    address public immutable factory;
    uint256 public immutable virtualQuote;
    uint256 public immutable graduationThreshold;
    uint256 public immutable poolDeadline;
    uint256 public immutable launchedAt;
    uint16 public immutable poolBps;
    uint16 public immutable issuerBps;
    uint16 public immutable platformBps;
    uint256 public immutable k;

    /// @dev Reserves are counted, never read from balances, so tokens or USDC
    /// pushed into this contract from outside cannot move the price.
    uint256 public realQuote;
    uint256 public tokenReserve;
    bool public graduated;
    bool public poolInitialized;

    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    uint256 public quoteInPool;
    uint256 public tokensInPool;
    uint256 public burnedAtGraduation;
    uint128 public liquidity;
    uint160 public graduationSqrtPriceX96;

    uint256 public totalFeesToPool;
    uint256 public totalFeesToIssuer;
    uint256 public totalFeesToPlatform;
    uint256 public totalSnipeTax;
    uint256 public totalTokenFeesBurned;

    uint256 private _lock = 1;
    bool private _unlocking;

    event Buy(
        address indexed buyer, address indexed recipient, uint256 quoteIn, uint256 fee, uint256 tax, uint256 tokensOut
    );
    event Sell(
        address indexed seller, address indexed receiver, uint256 tokensIn, uint256 gross, uint256 fee, uint256 net
    );
    event FeeDistributed(uint256 toPool, uint256 toIssuer, uint256 toPlatform, address platformTarget);
    event Claimed(address indexed account, address indexed receiver, uint256 amount);
    event PoolInitialized(PoolId indexed poolId, uint160 sqrtPriceX96);
    event Graduated(
        PoolId indexed poolId,
        uint256 quoteInPool,
        uint256 tokensInPool,
        uint256 burned,
        uint128 liquidity,
        uint160 sqrtPriceX96
    );
    event FeesCollected(uint256 quoteFees, uint256 tokenFees);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(Config memory c) {
        if (
            c.token == address(0) || c.vault == address(0) || c.issuer == address(0) || c.platformSink == address(0)
                || c.poolManager == address(0)
        ) revert ZeroAddress();
        if (uint256(c.poolBps) + c.issuerBps + c.platformBps != BPS) revert BadSplit();
        if (c.platformBps != 0 && c.officialVault == address(0)) revert BadSplit();

        token = LaunchToken(c.token);
        vault = RedemptionVault(payable(c.vault));
        issuer = c.issuer;
        officialVault = c.officialVault;
        officialDeadline = c.officialDeadline;
        platformSink = c.platformSink;
        poolManager = IPoolManager(c.poolManager);
        factory = c.factory;
        virtualQuote = c.virtualQuote;
        graduationThreshold = c.graduationThreshold;
        poolBps = c.poolBps;
        issuerBps = c.issuerBps;
        platformBps = c.platformBps;

        poolDeadline = RedemptionVault(payable(c.vault)).deadline();
        launchedAt = block.timestamp;
        tokenReserve = LaunchToken(c.token).TOTAL_SUPPLY();
        k = c.virtualQuote * tokenReserve;
    }

    /// @dev Only the pool manager pays this contract without calling a function
    /// (`take` during fee collection). Anything else is a mistake; refuse it so
    /// the money is not stranded.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
    }

    // ---------------------------------------------------------------- views

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
    }

    function poolId() public view returns (PoolId) {
        return poolKey().toId();
    }

    /// @notice Quote per token on the curve, scaled by 1e18. Zero once graduated.
    function spotPriceWad() external view returns (uint256) {
        if (tokenReserve == 0) return 0;
        return FullMath.mulDiv(virtualQuote + realQuote, 1e18, tokenReserve);
    }

    function graduationProgressBps() external view returns (uint256) {
        if (graduated) return BPS;
        return realQuote * BPS / graduationThreshold;
    }

    function quoteBuy(uint256 quoteIn, address recipient)
        public
        view
        returns (uint256 tokensOut, uint256 fee, uint256 tax)
    {
        fee = quoteIn * FEE_BPS / BPS;
        tax = _snipeTax(quoteIn - fee, recipient);
        (tokensOut,) = CurveMath.tokensOut(k, virtualQuote + realQuote, tokenReserve, quoteIn - fee - tax);
    }

    function quoteSell(uint256 tokensIn) public view returns (uint256 quoteOut, uint256 fee) {
        (uint256 gross,) = CurveMath.quoteOut(k, virtualQuote + realQuote, tokenReserve, tokensIn);
        fee = gross * FEE_BPS / BPS;
        quoteOut = gross - fee;
    }

    function _snipeTax(uint256 afterFee, address recipient) private view returns (uint256) {
        if (recipient == issuer) return 0;
        uint256 bps = CurveMath.snipeTaxBps(block.timestamp - launchedAt, SNIPE_TAX_SECONDS, SNIPE_TAX_MAX_BPS);
        return afterFee * bps / BPS;
    }

    // -------------------------------------------------------------- trading

    function buy(uint256 minTokensOut, address recipient) external payable nonReentrant returns (uint256 tokensOut) {
        if (graduated) revert AlreadyGraduated();
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroAmount();

        uint256 fee = msg.value * FEE_BPS / BPS;
        uint256 tax = _snipeTax(msg.value - fee, recipient);
        uint256 net = msg.value - fee - tax;

        uint256 newReserve;
        (tokensOut, newReserve) = CurveMath.tokensOut(k, virtualQuote + realQuote, tokenReserve, net);
        if (tokensOut == 0) revert ZeroAmount();
        if (tokensOut < minTokensOut) revert Slippage();

        realQuote += net;
        tokenReserve = newReserve;

        if (tax != 0) {
            totalSnipeTax += tax;
            _send(address(vault), tax);
        }
        _distribute(fee);
        token.transfer(recipient, tokensOut);
        emit Buy(msg.sender, recipient, msg.value, fee, tax, tokensOut);

        if (realQuote >= graduationThreshold) _graduate();
    }

    function sell(uint256 tokensIn, uint256 minQuoteOut, address receiver)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        if (graduated) revert AlreadyGraduated();
        if (receiver == address(0)) revert ZeroAddress();
        if (tokensIn == 0) revert ZeroAmount();

        token.transferFrom(msg.sender, address(this), tokensIn);
        (uint256 gross, uint256 newReserve) =
            CurveMath.quoteOut(k, virtualQuote + realQuote, tokenReserve, tokensIn);
        uint256 fee = gross * FEE_BPS / BPS;
        quoteOut = gross - fee;
        if (quoteOut == 0) revert ZeroAmount();
        if (quoteOut < minQuoteOut) revert Slippage();

        realQuote -= gross;
        tokenReserve = newReserve;

        _distribute(fee);
        _send(receiver, quoteOut);
        emit Sell(msg.sender, receiver, tokensIn, gross, fee, quoteOut);
    }

    /// @notice Pull a pending share (the issuer's cut, or the pool share once the
    /// pool has closed). `receiver` lets a claimant route around an address that
    /// cannot accept value.
    function claim(address receiver) external nonReentrant {
        if (receiver == address(0)) revert ZeroAddress();
        uint256 amount = claimable[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        _send(receiver, amount);
        emit Claimed(msg.sender, receiver, amount);
    }

    /// @dev Pool share is pushed to our vault while it is open, otherwise it
    /// joins the issuer's pending balance. The platform share is pushed to the
    /// official pool while that is open, otherwise to the sink. The issuer's
    /// own share is always pending, never pushed.
    function _distribute(uint256 amount) private {
        if (amount == 0) return;
        uint256 toPlatform = amount * platformBps / BPS;
        uint256 toIssuer = amount * issuerBps / BPS;
        uint256 toPool = amount - toPlatform - toIssuer;

        if (block.timestamp < poolDeadline) {
            totalFeesToPool += toPool;
            _send(address(vault), toPool);
        } else {
            claimable[issuer] += toPool;
            totalClaimable += toPool;
            totalFeesToIssuer += toPool;
        }

        claimable[issuer] += toIssuer;
        totalClaimable += toIssuer;
        totalFeesToIssuer += toIssuer;

        address target;
        if (toPlatform != 0) {
            target = block.timestamp < officialDeadline ? officialVault : platformSink;
            totalFeesToPlatform += toPlatform;
            _send(target, toPlatform);
        }
        emit FeeDistributed(toPool, toIssuer, toPlatform, target);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    // ----------------------------------------------------------- graduation

    /// @notice Claim the pool's key before anyone else can. Called by the
    /// factory in the launch transaction; harmless to call again.
    function initializePool() external {
        if (poolInitialized) return;
        (uint160 current,,,) = poolManager.getSlot0(poolId());
        if (current == 0) {
            uint160 start = CurveMath.sqrtPriceX96(virtualQuote, tokenReserve);
            poolManager.initialize(poolKey(), start);
            emit PoolInitialized(poolId(), start);
        }
        poolInitialized = true;
    }

    function _graduate() private {
        graduated = true;
        uint256 quoteToPool = realQuote;
        uint256 tokensToPool = FullMath.mulDiv(realQuote, tokenReserve, virtualQuote + realQuote);
        uint256 burn = tokenReserve - tokensToPool;
        realQuote = 0;
        tokenReserve = 0;
        if (burn != 0) token.burn(burn);

        uint160 target = CurveMath.sqrtPriceX96(quoteToPool, tokensToPool);
        _unlocking = true;
        bytes memory result = poolManager.unlock(abi.encode(CB_GRADUATE, quoteToPool, tokensToPool, target));
        _unlocking = false;
        (uint256 used0, uint256 used1, uint128 liq, uint160 price) =
            abi.decode(result, (uint256, uint256, uint128, uint160));

        quoteInPool = used0;
        tokensInPool = used1;
        liquidity = liq;
        graduationSqrtPriceX96 = price;
        burnedAtGraduation = burn;

        // Rounding leaves dust on both sides; neither may stay here.
        uint256 tokenDust = token.balanceOf(address(this));
        if (tokenDust != 0) {
            token.burn(tokenDust);
            burnedAtGraduation += tokenDust;
        }
        uint256 quoteDust = address(this).balance - totalClaimable;
        if (quoteDust != 0) _distribute(quoteDust);

        emit Graduated(poolId(), used0, used1, burnedAtGraduation, liq, price);
    }

    /// @notice Pull accrued LP fees out of the Uniswap position. USDC is split
    /// like any other fee; tokens are burned, which raises every holder's share.
    function collectFees() external nonReentrant returns (uint256 quoteFees, uint256 tokenFees) {
        if (!graduated) revert NotGraduated();
        _unlocking = true;
        bytes memory result = poolManager.unlock(abi.encode(CB_COLLECT, uint256(0), uint256(0), uint160(0)));
        _unlocking = false;
        (quoteFees, tokenFees) = abi.decode(result, (uint256, uint256));
        if (tokenFees != 0) {
            token.burn(tokenFees);
            totalTokenFeesBurned += tokenFees;
        }
        if (quoteFees != 0) _distribute(quoteFees);
        emit FeesCollected(quoteFees, tokenFees);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (!_unlocking) revert NotUnlocking();
        (uint8 op, uint256 a, uint256 b, uint160 c) = abi.decode(data, (uint8, uint256, uint256, uint160));
        if (op == CB_GRADUATE) return _seedPool(a, b, c);
        if (op == CB_COLLECT) return _collectInPool();
        revert UnknownCallback();
    }

    /// @dev Inside the pool manager's unlock. The pool may already be
    /// initialised by someone else, at any price: move it to ours first, then
    /// deposit whatever both balances allow at the price we actually reached.
    function _seedPool(uint256 quoteAmount, uint256 tokenAmount, uint160 target) private returns (bytes memory) {
        PoolKey memory key = poolKey();
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        if (price == 0) {
            poolManager.initialize(key, target);
            price = target;
        } else if (price != target) {
            price = _movePrice(key, price, target, quoteAmount, tokenAmount);
        }

        uint128 liq = _liquidityFor(price);
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER,
                tickUpper: TICK_UPPER,
                liquidityDelta: int256(uint256(liq)),
                salt: 0
            }),
            ""
        );
        uint256 owed0 = _owed(delta.amount0());
        uint256 owed1 = _owed(delta.amount1());
        poolManager.settle{value: owed0}();
        poolManager.sync(key.currency1);
        token.transfer(address(poolManager), owed1);
        poolManager.settle();
        return abi.encode(owed0, owed1, liq, price);
    }

    /// @dev Full-range liquidity for everything this contract holds that is not
    /// owed to a claimant, shaved a hair because Uniswap rounds the amounts it
    /// asks for up.
    function _liquidityFor(uint160 price) private view returns (uint128 liq) {
        uint256 quoteAvail = address(this).balance - totalClaimable;
        uint256 tokenAvail = token.balanceOf(address(this));
        liq = CurveMath.fullRangeLiquidity(
            price, TickMath.getSqrtPriceAtTick(TICK_LOWER), TickMath.getSqrtPriceAtTick(TICK_UPPER), quoteAvail, tokenAvail
        );
        liq -= uint128(liq / 1_000_000 + 1);
    }

    /// @dev Swap towards `target` with a capped budget. An empty pool moves for
    /// free; a pool someone stuffed with liquidity costs at most the budget and
    /// may stop short, in which case we deposit at the price we reached.
    function _movePrice(PoolKey memory key, uint160 current, uint160 target, uint256 quoteAmount, uint256 tokenAmount)
        private
        returns (uint160)
    {
        bool zeroForOne = current > target; // paying USDC lowers tokens-per-USDC
        uint256 budget = (zeroForOne ? quoteAmount : tokenAmount) * PRICE_MOVE_BUDGET_BPS / BPS;
        if (budget == 0) return current;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -int256(budget), sqrtPriceLimitX96: target}),
            ""
        );
        uint256 owed0 = _owed(delta.amount0());
        uint256 owed1 = _owed(delta.amount1());
        uint256 got0 = _got(delta.amount0());
        uint256 got1 = _got(delta.amount1());
        if (owed0 != 0) poolManager.settle{value: owed0}();
        if (owed1 != 0) {
            poolManager.sync(key.currency1);
            token.transfer(address(poolManager), owed1);
            poolManager.settle();
        }
        if (got0 != 0) poolManager.take(key.currency0, address(this), got0);
        if (got1 != 0) poolManager.take(key.currency1, address(this), got1);
        (uint160 price,,,) = poolManager.getSlot0(key.toId());
        return price;
    }

    function _collectInPool() private returns (bytes memory) {
        PoolKey memory key = poolKey();
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 0, salt: 0}),
            ""
        );
        uint256 fees0 = _got(delta.amount0());
        uint256 fees1 = _got(delta.amount1());
        if (fees0 != 0) poolManager.take(key.currency0, address(this), fees0);
        if (fees1 != 0) poolManager.take(key.currency1, address(this), fees1);
        return abi.encode(fees0, fees1);
    }

    function _owed(int128 amount) private pure returns (uint256) {
        return amount < 0 ? uint256(uint128(-amount)) : 0;
    }

    function _got(int128 amount) private pure returns (uint256) {
        return amount > 0 ? uint256(uint128(amount)) : 0;
    }
}
