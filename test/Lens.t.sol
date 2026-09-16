// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";
import {LaunchpadLens} from "../contracts/LaunchpadLens.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";

contract LensTest is ArcBase {
    LaunchFactory factory;
    LaunchpadLens lens;
    address owner = makeAddr("owner");
    address official;
    address third;
    LaunchFactory.Metadata meta = LaunchFactory.Metadata({logo: "l", description: "d", socials: "s"});

    function setUp() public override {
        super.setUp();
        factory = new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), owner, P, G, 1e18);
        lens = new LaunchpadLens(address(factory));
        vm.deal(owner, 100 ether);
        vm.prank(owner);
        (official,,) = factory.launchOfficial{value: 1e18}("Rehearsal", "REHRSL", meta, 0);
        vm.prank(issuer);
        (third,,) = factory.launch{value: 1e18}("Third", "THIRD", meta, 0);
        _later();
    }

    function test_TokenViewBeforeGraduation() public {
        vm.prank(bob);
        BondingCurve(payable(factory.curveOf(third))).buy{value: 1_000e18}(0, bob);
        LaunchpadLens.TokenView memory v = lens.tokenView(third);
        assertEq(v.token, third);
        assertEq(v.curve, factory.curveOf(third));
        assertEq(v.vault, factory.vaultOf(third));
        assertEq(v.issuer, issuer);
        assertEq(v.symbol, "THIRD");
        assertEq(v.phase, 0);
        assertEq(v.realQuote, 970e18);
        assertEq(v.virtualQuote, P);
        assertEq(v.graduationThreshold, G);
        assertEq(v.graduationProgressBps, 970e18 * 10_000 / G);
        assertEq(v.reserve, 25.5e18);
        assertGt(v.backingPerToken, 0);
        assertGt(v.spotPriceWad, P * 1e18 / SUPPLY);
        assertEq(v.issuerClaimable, 3e18);
        assertTrue(v.isOpen);
        assertEq(v.feeBps, 300);
        assertEq(v.poolBps, 8_500);
        assertEq(v.launchFee, 1e18);
        assertEq(v.lockedInPool, 0);
        assertEq(v.logo, "l");
    }

    function test_TokenViewAfterGraduation() public {
        BondingCurve curve = BondingCurve(payable(factory.curveOf(third)));
        vm.prank(bob);
        curve.buy{value: 9_000e18}(0, bob);
        LaunchpadLens.TokenView memory v = lens.tokenView(third);
        assertEq(v.phase, 1);
        assertEq(v.graduationProgressBps, 10_000);
        assertGt(v.liquidity, 0);
        assertGt(v.sqrtPriceX96, 0);
        assertGt(v.poolPriceWad, 0);
        // Tokens sitting in the locked position: close to what we deposited.
        assertApproxEqRel(v.lockedInPool, curve.tokensInPool(), 0.001e18);
        assertEq(v.spotPriceWad, 0);
    }

    function test_TokenViewsPagesAndSurvivesOverflow() public view {
        LaunchpadLens.TokenView[] memory all = lens.tokenViews(0, type(uint256).max);
        assertEq(all.length, 2);
        assertEq(all[0].token, official);
        assertEq(all[1].token, third);
        assertEq(lens.tokenViews(1, 10).length, 1);
        assertEq(lens.tokenViews(2, 10).length, 0);
    }

    function test_QuotesMatchTheCurve() public view {
        BondingCurve curve = BondingCurve(payable(factory.curveOf(third)));
        (uint256 a, uint256 b, uint256 c) = lens.quoteBuy(third, 100e18, bob);
        (uint256 a2, uint256 b2, uint256 c2) = curve.quoteBuy(100e18, bob);
        assertEq(a, a2);
        assertEq(b, b2);
        assertEq(c, c2);
        (uint256 q, uint256 f) = lens.quoteSell(third, 1e18);
        (uint256 q2, uint256 f2) = curve.quoteSell(1e18);
        assertEq(q, q2);
        assertEq(f, f2);
        assertEq(lens.previewRedeem(third, 1e18), 0); // pool is empty, nothing to redeem yet
    }

    function test_UnknownTokenReverts() public {
        vm.expectRevert(LaunchpadLens.UnknownToken.selector);
        lens.tokenView(address(0xdead));
        vm.expectRevert(LaunchpadLens.UnknownToken.selector);
        lens.quoteBuy(address(0xdead), 1, bob);
        vm.expectRevert(LaunchpadLens.UnknownToken.selector);
        lens.previewRedeem(address(0xdead), 1);
    }
}
