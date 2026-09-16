// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";
import {CurveMath} from "../contracts/CurveMath.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

/// @dev Stands in for an address Circle has blocklisted: any value sent to it reverts.
contract Blocklisted {
    receive() external payable {
        revert("blocklisted");
    }
}

contract ReentrantSeller {
    BondingCurve c;
    LaunchToken t;
    uint256 half;

    constructor(BondingCurve c_, LaunchToken t_) {
        c = c_;
        t = t_;
    }

    function go() external payable {
        uint256 got = c.buy{value: msg.value}(0, address(this));
        half = got / 2;
        t.approve(address(c), got);
        c.sell(half, 0, address(this));
    }

    receive() external payable {
        // Re-enter on the payout.
        c.sell(half, 0, address(this));
    }
}

contract MathCaller {
    function fullRange(uint160 sp, uint256 a0, uint256 a1) external pure returns (uint128) {
        return CurveMath.fullRangeLiquidity(sp, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE, a0, a1);
    }
}

contract AdversarialTest is ArcBase {
    using StateLibrary for IPoolManager;

    Trio official;
    Trio t;

    function setUp() public override {
        super.setUp();
        official = _official();
        t = _thirdParty(address(official.vault), official.vault.deadline());
        _later();
    }

    function test_BlocklistedSellerOnlyHurtsThemselves() public {
        Blocklisted bad = new Blocklisted();
        vm.prank(bob);
        uint256 got = t.curve.buy{value: 100e18}(0, bob);
        vm.startPrank(bob);
        t.token.approve(address(t.curve), got);
        vm.expectRevert(BondingCurve.TransferFailed.selector);
        t.curve.sell(got, 0, address(bad));
        // The same seller succeeds to a normal receiver, and everyone else keeps trading.
        t.curve.sell(got, 0, bob);
        vm.stopPrank();
        vm.prank(carol);
        t.curve.buy{value: 1e18}(0, carol);
    }

    function test_BlocklistedIssuerCannotFreezeTrading() public {
        Blocklisted badIssuer = new Blocklisted();
        Trio memory f = _deployTrio(address(badIssuer), address(official.vault), official.vault.deadline(), G, 8_500, 500);
        _later();
        vm.prank(bob);
        f.curve.buy{value: 100e18}(0, bob); // would revert if the issuer's 10% were pushed
        assertEq(f.curve.claimable(address(badIssuer)), 0.3e18);
    }

    function test_ReentrantSellIsBlocked() public {
        ReentrantSeller r = new ReentrantSeller(t.curve, t.token);
        // The inner sell reverts with Reentrancy, so the outer payout fails.
        vm.expectRevert(BondingCurve.TransferFailed.selector);
        r.go{value: 100e18}();
    }

    function test_CurveRefusesStrayValue() public {
        (bool ok,) = address(t.curve).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_SellCanNeverExceedRealReserve() public {
        vm.prank(bob);
        uint256 got = t.curve.buy{value: 5_000e18}(0, bob);
        vm.prank(carol);
        uint256 got2 = t.curve.buy{value: 2_000e18}(0, carol);
        uint256 reserve = t.curve.realQuote();
        vm.startPrank(bob);
        t.token.approve(address(t.curve), got);
        uint256 out1 = t.curve.sell(got, 0, bob);
        vm.stopPrank();
        vm.startPrank(carol);
        t.token.approve(address(t.curve), got2);
        uint256 out2 = t.curve.sell(got2, 0, carol);
        vm.stopPrank();
        assertLe(out1 + out2, reserve);
        assertEq(t.curve.tokenReserve(), SUPPLY);
        assertEq(address(t.curve).balance, t.curve.realQuote() + t.curve.totalClaimable());
    }

    function test_SameSecondBlocksAllPaySnipeTax() public {
        Trio memory f = _thirdParty(address(official.vault), official.vault.deadline());
        // Arc: sub-second blocks share a timestamp; every buyer in the launch second pays 99%.
        vm.roll(block.number + 1);
        (,, uint256 tax) = f.curve.quoteBuy(100e18, bob);
        assertEq(tax, 97e18 * 9_900 / 10_000);
        vm.roll(block.number + 1);
        (,, uint256 tax2) = f.curve.quoteBuy(100e18, carol);
        assertEq(tax2, tax);
    }

    function test_BurningCirculatingTokensDoesNotMoveTheCurve() public {
        vm.prank(bob);
        uint256 got = t.curve.buy{value: 1_000e18}(0, bob);
        (uint256 before,,) = t.curve.quoteBuy(100e18, carol);
        vm.prank(bob);
        t.token.burn(got / 2);
        (uint256 after_,,) = t.curve.quoteBuy(100e18, carol);
        assertEq(before, after_);
    }

    function test_SellingDustRevertsInsteadOfPayingNothing() public {
        vm.prank(bob);
        t.curve.buy{value: 1e18}(0, bob);
        vm.startPrank(bob);
        t.token.approve(address(t.curve), 1);
        vm.expectRevert(BondingCurve.ZeroAmount.selector);
        t.curve.sell(1, 0, bob);
        vm.stopPrank();
    }

    function test_LaunchRevertsIfTheSinkRefusesTheFee() public {
        Blocklisted badSink = new Blocklisted();
        LaunchFactory f = new LaunchFactory(POOL_MANAGER, address(deployer), address(badSink), issuer, P, G, 1e18);
        LaunchFactory.Metadata memory meta = LaunchFactory.Metadata({logo: "", description: "", socials: ""});
        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.TransferFailed.selector);
        f.launchOfficial{value: 1e18}("X", "X", meta, 0);
    }

    function test_LiquidityOverflowIsCaught() public {
        // Internal library calls are inlined, so route through an external frame for expectRevert.
        MathCaller m = new MathCaller();
        vm.expectRevert(bytes("liquidity overflow"));
        m.fullRange(TickMath.getSqrtPriceAtTick(0), 2 ** 200, 2 ** 200);
    }
}
