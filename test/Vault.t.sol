// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {MockToken, RejectEth} from "./Mocks.sol";

/// @dev Re-enters `redeem` from inside its own payout.
contract Reenterer {
    RedemptionVault v;
    MockToken t;

    constructor(RedemptionVault v_, MockToken t_) {
        v = v_;
        t = t_;
    }

    function go(uint256 q) external {
        t.approve(address(v), type(uint256).max);
        v.redeem(q, 0, block.timestamp, address(this));
    }

    receive() external payable {
        v.redeem(1e18, 0, block.timestamp, address(this));
    }
}

contract VaultTest is Test {
    uint256 constant SUPPLY = 1_000_000_000e18;
    MockToken token;
    RedemptionVault vault;
    address issuer = makeAddr("issuer");
    address alice = makeAddr("alice");
    uint256 deadline;

    function setUp() public {
        token = new MockToken(SUPPLY, address(this));
        deadline = block.timestamp + 30 days;
        vault = new RedemptionVault(address(token), deadline, issuer);
        token.transfer(alice, 100_000_000e18); // 10% of supply
        vm.prank(alice);
        token.approve(address(vault), type(uint256).max);
        vm.deal(address(this), 1000 ether);
    }

    function _fund(uint256 amount) internal {
        (bool ok,) = address(vault).call{value: amount}("");
        require(ok);
    }

    function test_FundRaisesReserve() public {
        _fund(10 ether);
        assertEq(vault.reserve(), 10 ether);
        assertEq(vault.totalFunded(), 10 ether);
        vault.fund{value: 5 ether}();
        assertEq(vault.reserve(), 15 ether);
    }

    function test_RedeemPaysProportionalShare() public {
        _fund(100 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 out = vault.redeem(10_000_000e18, 0, block.timestamp, alice); // 1% of supply
        assertEq(out, 1 ether);
        assertEq(alice.balance - before, 1 ether);
        assertEq(vault.reserve(), 99 ether);
        assertEq(vault.totalRedeemed(), 1 ether);
        assertEq(vault.totalBurned(), 10_000_000e18);
        assertEq(token.totalSupply(), SUPPLY - 10_000_000e18);
    }

    function test_ProportionalRedemptionPreservesUnitBacking() public {
        _fund(100 ether);
        uint256 unitBefore = vault.backingPerToken();
        vm.prank(alice);
        vault.redeem(50_000_000e18, 0, block.timestamp, alice);
        assertEq(vault.backingPerToken(), unitBefore);
    }

    function test_PreviewMatchesRedeem() public {
        _fund(123.456 ether);
        uint256 q = 7_777_777e18;
        uint256 preview = vault.previewRedeem(q);
        vm.prank(alice);
        assertEq(vault.redeem(q, 0, block.timestamp, alice), preview);
    }

    function test_ZeroPayoutRefusesAndDoesNotBurn() public {
        _fund(1); // 1 wei
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.ZeroPayout.selector);
        vault.redeem(1, 0, block.timestamp, alice);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_SlippageIsEnforced() public {
        _fund(100 ether);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.Slippage.selector);
        vault.redeem(10_000_000e18, 1 ether + 1, block.timestamp, alice);
    }

    function test_ExpiredQuoteReverts() public {
        _fund(100 ether);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.QuoteExpired.selector);
        vault.redeem(1e18, 0, block.timestamp - 1, alice);
    }

    function test_RedeemZeroAmountReverts() public {
        _fund(1 ether);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.ZeroAmount.selector);
        vault.redeem(0, 0, block.timestamp, alice);
    }

    function test_RedeemToZeroReceiverReverts() public {
        _fund(1 ether);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.ZeroAddress.selector);
        vault.redeem(1e18, 0, block.timestamp, address(0));
    }

    function test_RedeemToRejectingReceiverReverts() public {
        _fund(100 ether);
        RejectEth r = new RejectEth();
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.TransferFailed.selector);
        vault.redeem(1_000_000e18, 0, block.timestamp, address(r));
    }

    function test_DishonestBurnIsRejected() public {
        _fund(100 ether);
        token.setHonest(false);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.SupplyMismatch.selector);
        vault.redeem(1e18, 0, block.timestamp, alice);
    }

    function test_WindowClosesAtDeadline() public {
        _fund(100 ether);
        vm.warp(deadline - 1);
        assertTrue(vault.isOpen());
        vm.prank(alice);
        vault.redeem(1e18, 0, block.timestamp, alice);

        vm.warp(deadline);
        assertFalse(vault.isOpen());
        assertEq(vault.previewRedeem(1e18), 0);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.WindowClosed.selector);
        vault.redeem(1e18, 0, block.timestamp, alice);
    }

    function test_ResidualOnlyIssuerAndOnlyAfterDeadline() public {
        _fund(100 ether);
        vm.prank(issuer);
        vm.expectRevert(RedemptionVault.WindowOpen.selector);
        vault.withdrawResidual(issuer);

        vm.warp(deadline);
        vm.prank(alice);
        vm.expectRevert(RedemptionVault.NotIssuer.selector);
        vault.withdrawResidual(alice);

        vm.prank(issuer);
        vm.expectRevert(RedemptionVault.ZeroAddress.selector);
        vault.withdrawResidual(address(0));
    }

    function test_ResidualSweepsEntireBalanceOnce() public {
        _fund(100 ether);
        vm.deal(address(vault), address(vault).balance + 3 ether); // forced value, not counted in reserve
        assertEq(vault.reserve(), 100 ether);
        vm.warp(deadline);
        address receiver = makeAddr("receiver");
        vm.prank(issuer);
        vault.withdrawResidual(receiver);
        assertEq(receiver.balance, 103 ether);
        assertEq(vault.reserve(), 0);
        assertEq(vault.residualPaid(), 103 ether);
        assertTrue(vault.residualSwept());

        vm.prank(issuer);
        vm.expectRevert(RedemptionVault.AlreadySwept.selector);
        vault.withdrawResidual(receiver);
    }

    function test_FundRefusedAfterSweep() public {
        _fund(1 ether);
        vm.warp(deadline);
        vm.prank(issuer);
        vault.withdrawResidual(issuer);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_FundStillAcceptedBetweenDeadlineAndSweep() public {
        vm.warp(deadline);
        _fund(1 ether);
        assertEq(vault.reserve(), 1 ether);
    }

    function test_ReentrantRedeemIsBlocked() public {
        _fund(100 ether);
        Reenterer r = new Reenterer(vault, token);
        token.transfer(address(r), 10e18);
        // The inner call reverts with Reentrancy; the outer one sees a failed payout.
        vm.expectRevert(RedemptionVault.TransferFailed.selector);
        r.go(5e18);
    }

    function test_ConstructorRejectsBadArgs() public {
        vm.expectRevert(RedemptionVault.ZeroAddress.selector);
        new RedemptionVault(address(0), deadline, issuer);
        vm.expectRevert(RedemptionVault.ZeroAddress.selector);
        new RedemptionVault(address(token), deadline, address(0));
        vm.expectRevert(RedemptionVault.DeadlineInPast.selector);
        new RedemptionVault(address(token), block.timestamp, issuer);
    }

    function test_ViewsHandleZeroSupply() public {
        MockToken empty = new MockToken(0, address(this));
        RedemptionVault v = new RedemptionVault(address(empty), deadline, issuer);
        (bool ok,) = address(v).call{value: 1 ether}("");
        require(ok);
        assertEq(v.previewRedeem(1), 0);
        assertEq(v.backingPerToken(), 0);
    }
}
