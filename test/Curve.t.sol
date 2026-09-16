// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";

contract CurveTest is ArcBase {
    Trio official;
    Trio t;

    function setUp() public override {
        super.setUp();
        official = _official();
        // A huge threshold keeps graduation out of this file; Graduation.t.sol covers it.
        t = _deployTrio(issuer, address(official.vault), official.vault.deadline(), type(uint128).max, 8_500, 500);
        _later();
    }

    function test_ConstructorState() public view {
        assertEq(t.curve.tokenReserve(), SUPPLY);
        assertEq(t.curve.realQuote(), 0);
        assertEq(t.curve.k(), P * SUPPLY);
        assertEq(t.curve.poolDeadline(), t.vault.deadline());
        assertEq(t.curve.factory(), address(this));
        assertEq(t.token.balanceOf(address(t.curve)), SUPPLY);
        assertFalse(t.curve.graduated());
    }

    function test_BuySplitsFeeAndDeliversTokens() public {
        uint256 quoteIn = 1_000e18;
        (uint256 expectedOut, uint256 fee, uint256 tax) = t.curve.quoteBuy(quoteIn, bob);
        assertEq(fee, 30e18);
        assertEq(tax, 0);

        vm.prank(bob);
        uint256 out = t.curve.buy{value: quoteIn}(expectedOut, bob);
        assertEq(out, expectedOut);
        assertEq(t.token.balanceOf(bob), out);
        assertEq(t.curve.realQuote(), 970e18);
        assertEq(t.vault.reserve(), 25.5e18); // 85% of 30
        assertEq(t.curve.claimable(issuer), 3e18); // 10%
        assertEq(official.vault.reserve(), 1.5e18); // 5% routed to the official pool
        assertEq(address(t.curve).balance, t.curve.realQuote() + t.curve.totalClaimable());
    }

    function test_BuyRevertsOnSlippageZeroValueZeroRecipient() public {
        (uint256 expectedOut,,) = t.curve.quoteBuy(1e18, bob);
        vm.startPrank(bob);
        vm.expectRevert(BondingCurve.Slippage.selector);
        t.curve.buy{value: 1e18}(expectedOut + 1, bob);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        t.curve.buy{value: 0}(0, bob);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        t.curve.buy{value: 1e18}(0, address(0));
        vm.stopPrank();
    }

    function test_SellReturnsQuoteMinusFee() public {
        vm.prank(bob);
        uint256 out = t.curve.buy{value: 1_000e18}(0, bob);
        (uint256 expectedQuote, uint256 fee) = t.curve.quoteSell(out);
        assertGt(expectedQuote, 0);
        assertEq(fee, (expectedQuote + fee) * 300 / 10_000);

        vm.startPrank(bob);
        t.token.approve(address(t.curve), out);
        uint256 balBefore = bob.balance;
        uint256 got = t.curve.sell(out, expectedQuote, bob);
        vm.stopPrank();
        assertEq(got, expectedQuote);
        assertEq(bob.balance - balBefore, got);
        assertEq(t.token.balanceOf(bob), 0);
        assertEq(t.curve.tokenReserve(), SUPPLY);
        // Round trip: bob paid 1000, got back less; the difference sits in fees and rounding dust.
        assertLt(got, 1_000e18);
        assertGe((P + t.curve.realQuote()) * t.curve.tokenReserve(), t.curve.k());
        assertEq(address(t.curve).balance, t.curve.realQuote() + t.curve.totalClaimable());
    }

    function test_SellRevertsOnSlippageAndZero() public {
        vm.prank(bob);
        uint256 out = t.curve.buy{value: 100e18}(0, bob);
        vm.startPrank(bob);
        t.token.approve(address(t.curve), out);
        vm.expectRevert(BondingCurve.Slippage.selector);
        t.curve.sell(out, type(uint256).max, bob);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        t.curve.sell(0, 0, bob);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        t.curve.sell(out, 0, address(0));
        vm.stopPrank();
    }

    function test_SnipeTaxDecaysAndFeedsThePool() public {
        Trio memory f = _thirdParty(address(official.vault), official.vault.deadline()); // launched right now
        // t = 0: 99% of the post-fee amount
        (uint256 out0, uint256 fee0, uint256 tax0) = f.curve.quoteBuy(100e18, bob);
        assertEq(fee0, 3e18);
        assertEq(tax0, 97e18 * 9_900 / 10_000);
        uint256 vaultBefore = f.vault.reserve();
        vm.prank(bob);
        f.curve.buy{value: 100e18}(out0, bob);
        assertEq(f.vault.reserve() - vaultBefore, tax0 + fee0 * 8_500 / 10_000);
        assertEq(f.curve.totalSnipeTax(), tax0);

        vm.warp(block.timestamp + 1);
        (,, uint256 tax1) = f.curve.quoteBuy(100e18, bob);
        assertEq(tax1, 97e18 * 6_600 / 10_000);
        vm.warp(block.timestamp + 2);
        (,, uint256 tax3) = f.curve.quoteBuy(100e18, bob);
        assertEq(tax3, 0);
    }

    function test_IssuerIsExemptFromSnipeTax() public {
        Trio memory f = _thirdParty(address(official.vault), official.vault.deadline());
        (,, uint256 tax) = f.curve.quoteBuy(100e18, issuer);
        assertEq(tax, 0);
        vm.prank(bob); // anyone may pay, the recipient decides the exemption
        f.curve.buy{value: 100e18}(0, issuer);
        assertEq(f.curve.totalSnipeTax(), 0);
        assertGt(f.token.balanceOf(issuer), 0);
    }

    function test_IssuerClaimsToAnyReceiver() public {
        vm.prank(bob);
        t.curve.buy{value: 1_000e18}(0, bob);
        address cold = makeAddr("cold");
        vm.prank(issuer);
        t.curve.claim(cold);
        assertEq(cold.balance, 3e18);
        assertEq(t.curve.claimable(issuer), 0);
        assertEq(t.curve.totalClaimable(), 0);

        vm.prank(issuer);
        vm.expectRevert(BondingCurve.NothingToClaim.selector);
        t.curve.claim(cold);
        vm.prank(issuer);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        t.curve.claim(address(0));
    }

    function test_PoolShareGoesToIssuerOncePoolCloses() public {
        vm.warp(t.vault.deadline());
        uint256 vaultBefore = t.vault.reserve();
        vm.prank(bob);
        t.curve.buy{value: 1_000e18}(0, bob);
        assertEq(t.vault.reserve(), vaultBefore);
        assertEq(t.curve.claimable(issuer), 25.5e18 + 3e18);
        // Both vaults were created in the same second, so the official pool has closed too: 5% goes to the sink.
        assertEq(address(sink).balance, 1.5e18);
        assertEq(official.vault.reserve(), 0);
    }

    function test_PlatformShareGoesToSinkOnceOfficialPoolCloses() public {
        vm.warp(official.vault.deadline());
        Trio memory f = _deployTrio(issuer, address(official.vault), official.vault.deadline(), type(uint128).max, 8_500, 500);
        _later();
        vm.prank(bob);
        f.curve.buy{value: 1_000e18}(0, bob);
        assertEq(address(sink).balance, 1.5e18);
        assertEq(official.vault.reserve(), 0);
    }

    function test_OfficialCurveHasNoPlatformSlice() public {
        vm.prank(bob);
        official.curve.buy{value: 1_000e18}(0, bob);
        assertEq(official.vault.reserve(), 27e18); // 90% of 30
        assertEq(official.curve.claimable(issuer), 3e18);
        assertEq(address(sink).balance, 0);
    }

    function test_DonationsDoNotMovePrice() public {
        (uint256 outBefore,,) = t.curve.quoteBuy(100e18, bob);
        vm.prank(bob);
        uint256 got = t.curve.buy{value: 100e18}(0, bob);
        vm.prank(bob);
        t.token.transfer(address(t.curve), got / 2); // donate tokens
        (bool ok,) = address(t.curve).call{value: 1 ether}(""); // donate quote: refused
        assertFalse(ok);
        (uint256 outAfter,,) = t.curve.quoteBuy(100e18, bob);
        assertLt(outAfter, outBefore); // only bob's real buy moved it
        assertEq(t.curve.tokenReserve(), SUPPLY - got);
    }

    function test_ConstructorRejectsBadConfig() public {
        BondingCurve.Config memory c = BondingCurve.Config({
            factory: address(this),
            token: address(t.token),
            vault: address(t.vault),
            issuer: issuer,
            officialVault: address(0),
            officialDeadline: 0,
            platformSink: address(sink),
            poolManager: POOL_MANAGER,
            virtualQuote: P,
            graduationThreshold: G,
            poolBps: 8_500,
            issuerBps: 1_000,
            platformBps: 500
        });
        vm.expectRevert(BondingCurve.BadSplit.selector); // platform slice but no official vault
        new BondingCurve(c);
        c.platformBps = 600;
        c.officialVault = address(official.vault);
        vm.expectRevert(BondingCurve.BadSplit.selector); // does not sum to 100%
        new BondingCurve(c);
        c.platformBps = 500;
        c.token = address(0);
        vm.expectRevert(BondingCurve.ZeroAddress.selector);
        new BondingCurve(c);
    }
}
