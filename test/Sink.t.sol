// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlatformSink} from "../contracts/PlatformSink.sol";
import {RejectEth} from "./Mocks.sol";

/**
 * @notice PlatformSink holds every token's platform slice for the life of the
 * launchpad and its address is immutable inside every vault, so the only thing
 * that can ever be changed here is who controls it. That handover is the whole
 * point of the contract existing, and it is what these tests cover.
 */
contract SinkTest is Test {
    PlatformSink sink;
    address owner = address(0x0E1);
    address next = address(0x0E2);
    address stranger = address(0x5747);
    address payee = address(0xBEEF);

    function setUp() public {
        sink = new PlatformSink(owner);
        vm.deal(address(this), 100 ether);
    }

    function test_ConstructorRejectsZeroOwner() public {
        vm.expectRevert(PlatformSink.ZeroAddress.selector);
        new PlatformSink(address(0));
    }

    function test_ReceivesPlainTransfers() public {
        (bool ok,) = address(sink).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(address(sink).balance, 3 ether);
    }

    // ---------------- withdrawals ----------------

    function test_OwnerCanWithdrawPart() public {
        (bool ok,) = address(sink).call{value: 5 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        sink.withdraw(payee, 2 ether);
        assertEq(payee.balance, 2 ether);
        assertEq(address(sink).balance, 3 ether);
    }

    function test_OwnerCanWithdrawAll() public {
        (bool ok,) = address(sink).call{value: 5 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        sink.withdrawAll(payee);
        assertEq(payee.balance, 5 ether);
        assertEq(address(sink).balance, 0);
    }

    function test_StrangerCannotWithdraw() public {
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(stranger);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.withdraw(stranger, 1 ether);

        vm.prank(stranger);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.withdrawAll(stranger);
        assertEq(address(sink).balance, 1 ether, "balance untouched");
    }

    function test_WithdrawToZeroReverts() public {
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertTrue(ok);
        vm.startPrank(owner);
        vm.expectRevert(PlatformSink.ZeroAddress.selector);
        sink.withdraw(address(0), 1);
        vm.expectRevert(PlatformSink.ZeroAddress.selector);
        sink.withdrawAll(address(0));
        vm.stopPrank();
    }

    function test_WithdrawToRejectingReceiverReverts() public {
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertTrue(ok);
        address bad = address(new RejectEth());
        vm.startPrank(owner);
        vm.expectRevert(PlatformSink.PayoutFailed.selector);
        sink.withdraw(bad, 1 ether);
        vm.expectRevert(PlatformSink.PayoutFailed.selector);
        sink.withdrawAll(bad);
        vm.stopPrank();
        assertEq(address(sink).balance, 1 ether, "nothing lost on a failed payout");
    }

    function test_WithdrawMoreThanHeldReverts() public {
        (bool ok,) = address(sink).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        vm.expectRevert();
        sink.withdraw(payee, 2 ether);
    }

    // ---------------- ownership handover ----------------

    /// @notice Two steps on purpose: a typo in the new owner cannot brick the
    /// sink, because nothing changes until the new owner accepts.
    function test_HandoverIsTwoSteps() public {
        vm.prank(owner);
        sink.transferOwnership(next);
        assertEq(sink.owner(), owner, "still the old owner until accepted");
        assertEq(sink.pendingOwner(), next);

        vm.prank(next);
        sink.acceptOwnership();
        assertEq(sink.owner(), next);
        assertEq(sink.pendingOwner(), address(0));
    }

    function test_NewOwnerControlsTheMoneyAndOldOneDoesNot() public {
        (bool ok,) = address(sink).call{value: 4 ether}("");
        assertTrue(ok);
        vm.prank(owner);
        sink.transferOwnership(next);
        vm.prank(next);
        sink.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.withdrawAll(owner);

        vm.prank(next);
        sink.withdrawAll(payee);
        assertEq(payee.balance, 4 ether);
    }

    function test_StrangerCannotStartOrAcceptHandover() public {
        vm.prank(stranger);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.transferOwnership(stranger);

        vm.prank(owner);
        sink.transferOwnership(next);
        vm.prank(stranger);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.acceptOwnership();
        assertEq(sink.owner(), owner);
    }

    function test_TransferToZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(PlatformSink.ZeroAddress.selector);
        sink.transferOwnership(address(0));
    }

    function test_PendingCanBeReplacedBeforeAcceptance() public {
        vm.startPrank(owner);
        sink.transferOwnership(next);
        sink.transferOwnership(stranger);
        vm.stopPrank();
        assertEq(sink.pendingOwner(), stranger);

        vm.prank(next);
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.acceptOwnership();
    }

    /// @notice Accepting twice must fail: pendingOwner is cleared on the way.
    function test_AcceptCannotBeReplayed() public {
        vm.prank(owner);
        sink.transferOwnership(next);
        vm.startPrank(next);
        sink.acceptOwnership();
        vm.expectRevert(PlatformSink.NotOwner.selector);
        sink.acceptOwnership();
        vm.stopPrank();
    }
}
