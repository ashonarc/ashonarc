// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";

contract TokenTest is Test {
    LaunchToken t;

    function setUp() public {
        t = new LaunchToken("Rehearsal", "REHRSL");
    }

    function test_MintsWholeSupplyToDeployer() public view {
        assertEq(t.totalSupply(), 1_000_000_000e18);
        assertEq(t.balanceOf(address(this)), 1_000_000_000e18);
        assertEq(t.decimals(), 18);
        assertEq(t.name(), "Rehearsal");
        assertEq(t.symbol(), "REHRSL");
    }

    function test_BurnReducesSupply() public {
        t.burn(10e18);
        assertEq(t.totalSupply(), 1_000_000_000e18 - 10e18);
    }

    function test_BurnFromNeedsAllowance() public {
        address spender = makeAddr("spender");
        vm.prank(spender);
        vm.expectRevert();
        t.burnFrom(address(this), 1e18);

        t.approve(spender, 1e18);
        vm.prank(spender);
        t.burnFrom(address(this), 1e18);
        assertEq(t.totalSupply(), 1_000_000_000e18 - 1e18);
    }
}
