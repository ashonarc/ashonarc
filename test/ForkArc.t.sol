// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PlatformSink} from "../contracts/PlatformSink.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";
import {LaunchpadLens} from "../contracts/LaunchpadLens.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {CurveDeployer} from "../contracts/CurveDeployer.sol";

/// @notice Against the real PoolManager on an Arc mainnet fork. Run on its own:
///   forge test --match-path test/ForkArc.t.sol -vv
contract ForkArcTest is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 constant P = 5_000e18;
    uint256 constant G = 10_000e18;

    LaunchFactory factory;
    LaunchpadLens lens;
    PoolSwapTest router;
    address owner = makeAddr("owner");
    address issuer = makeAddr("issuer");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.mainnet.arc.io")));
        assertEq(block.chainid, 5042);
        assertGt(POOL_MANAGER.code.length, 20_000);
        PlatformSink sink = new PlatformSink(owner);
        CurveDeployer deployer = new CurveDeployer();
        factory = new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), owner, P, G, 1e18);
        lens = new LaunchpadLens(address(factory));
        router = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        vm.deal(owner, 100e18);
        vm.deal(issuer, 100e18);
        vm.deal(bob, 100_000e18);
    }

    function test_FullLifecycleOnMainnetFork() public {
        LaunchFactory.Metadata memory meta = LaunchFactory.Metadata({logo: "", description: "", socials: ""});
        vm.prank(owner);
        (address official,,) = factory.launchOfficial{value: 1e18 + 1e18}("Rehearsal", "REHRSL", meta, 1e18);
        vm.warp(block.timestamp + 10);
        vm.prank(issuer);
        (address token, address curveAddr, address vaultAddr) = factory.launch{value: 1e18}("Third", "THIRD", meta, 0);
        BondingCurve curve = BondingCurve(payable(curveAddr));
        RedemptionVault vault = RedemptionVault(payable(vaultAddr));
        RedemptionVault officialVault = RedemptionVault(payable(factory.vaultOf(official)));
        vm.warp(block.timestamp + 10); // past the snipe window of the third-party launch

        // curve trading
        vm.prank(bob);
        uint256 got = curve.buy{value: 1_000e18}(0, bob);
        assertGt(got, 0);
        // 90% of the official dev buy's 0.03 fee, plus 5% of bob's 30 fee on the third-party token.
        assertEq(officialVault.reserve(), 0.027e18 + 1.5e18);

        // graduation on the real pool manager
        vm.prank(bob);
        curve.buy{value: 10_500e18}(0, bob);
        assertTrue(curve.graduated());
        assertEq(LaunchToken(token).balanceOf(curveAddr), 0);
        emit log_named_uint("graduation liquidity", curve.liquidity());

        // real Uniswap swap, then collect
        PoolKey memory key = curve.poolKey();
        vm.prank(bob);
        router.swap{value: 50e18}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(50e18),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 vaultBefore = vault.reserve();
        (uint256 quoteFees,) = curve.collectFees();
        assertApproxEqRel(quoteFees, 0.5e18, 0.001e18);
        assertGt(vault.reserve(), vaultBefore);

        // redeem
        vm.startPrank(bob);
        LaunchToken(token).approve(vaultAddr, type(uint256).max);
        uint256 q = LaunchToken(token).balanceOf(bob) / 10;
        uint256 preview = vault.previewRedeem(q);
        uint256 paid = vault.redeem(q, preview, block.timestamp, bob);
        vm.stopPrank();
        assertEq(paid, preview);
        assertGt(paid, 0);

        LaunchpadLens.TokenView memory v = lens.tokenView(token);
        assertEq(v.phase, 1);
        assertGt(v.lockedInPool, 0);
        emit log_named_uint("tokens locked in pool", v.lockedInPool);
        emit log_named_uint("pool price (USDC per token, 1e18)", v.poolPriceWad);
    }
}
