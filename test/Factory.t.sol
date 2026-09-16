// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ArcBase} from "./ArcBase.t.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

contract FactoryTest is ArcBase {
    using StateLibrary for IPoolManager;

    LaunchFactory factory;
    address owner = makeAddr("owner");
    LaunchFactory.Metadata meta =
        LaunchFactory.Metadata({logo: "ipfs://logo", description: "test", socials: "x.com/AshonArc"});

    function setUp() public override {
        super.setUp();
        factory = new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), owner, P, G, 1e18);
        vm.deal(owner, 1_000 ether);
    }

    function _launchOfficial() internal returns (address token) {
        vm.prank(owner);
        (token,,) = factory.launchOfficial{value: 1e18 + 2e18}("Rehearsal", "REHRSL", meta, 2e18);
    }

    function test_ConstructorAndConstants() public view {
        assertEq(address(factory.poolManager()), POOL_MANAGER);
        assertEq(address(factory.curveDeployer()), address(deployer));
        assertEq(factory.platformSink(), address(sink));
        assertEq(factory.owner(), owner);
        assertEq(factory.virtualQuote(), P);
        assertEq(factory.graduationThreshold(), G);
        assertEq(factory.launchFee(), 1e18);
        assertEq(factory.WINDOW(), 30 days);
        assertEq(uint256(factory.POOL_BPS()) + factory.ISSUER_BPS() + factory.PLATFORM_BPS(), 10_000);
        assertEq(uint256(factory.OFFICIAL_POOL_BPS()) + factory.ISSUER_BPS() + factory.OFFICIAL_PLATFORM_BPS(), 10_000);
    }

    function test_ThirdPartyLaunchRequiresOfficialFirst() public {
        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.OfficialNotLaunched.selector);
        factory.launch{value: 1e18}("X", "X", meta, 0);
    }

    function test_OnlyOwnerLaunchesOfficialAndOnlyOnce() public {
        vm.prank(issuer);
        vm.expectRevert(LaunchFactory.NotOwner.selector);
        factory.launchOfficial{value: 1e18}("X", "X", meta, 0);

        _launchOfficial();
        vm.prank(owner);
        vm.expectRevert(LaunchFactory.AlreadyLaunched.selector);
        factory.launchOfficial{value: 1e18}("X", "X", meta, 0);
    }

    function test_OfficialLaunchWiresEverything() public {
        address token = _launchOfficial();
        address curveAddr = factory.curveOf(token);
        address vaultAddr = factory.vaultOf(token);
        BondingCurve curve = BondingCurve(payable(curveAddr));
        RedemptionVault vault = RedemptionVault(payable(vaultAddr));

        assertEq(factory.officialToken(), token);
        assertEq(factory.officialVault(), vaultAddr);
        assertEq(factory.officialDeadline(), vault.deadline());
        assertEq(vault.deadline(), block.timestamp + 30 days);
        assertEq(vault.issuer(), owner);
        assertEq(curve.issuer(), owner);
        assertEq(curve.platformBps(), 0);
        assertEq(curve.poolBps(), 9_000);
        assertEq(curve.factory(), address(factory));
        assertEq(factory.launchCount(), 1);
        assertEq(factory.launchedTokens(0), token);
        assertEq(address(sink).balance, 1e18); // launch fee
        // dev buy delivered to the owner, tax-exempt
        assertGt(LaunchToken(token).balanceOf(owner), 0);
        assertEq(curve.totalSnipeTax(), 0);
        assertEq(curve.realQuote(), 2e18 * 9_700 / 10_000);
        // supply lives on the curve minus the dev buy; nothing stuck in the factory
        assertEq(LaunchToken(token).balanceOf(address(factory)), 0);
        assertEq(address(factory).balance, 0);
        // pool claimed
        (uint160 price,,,) = manager.getSlot0(curve.poolId());
        assertGt(price, 0);
        LaunchFactory.Metadata memory m = factory.metadataOf(token);
        assertEq(m.logo, "ipfs://logo");
        assertEq(m.socials, "x.com/AshonArc");
    }

    function test_ThirdPartyLaunchRoutesFivePercentToOfficialPool() public {
        address official = _launchOfficial();
        RedemptionVault officialVault = RedemptionVault(payable(factory.vaultOf(official)));
        _later();
        vm.prank(issuer);
        (address token, address curveAddr,) = factory.launch{value: 1e18}("Third", "THIRD", meta, 0);
        BondingCurve curve = BondingCurve(payable(curveAddr));
        assertEq(curve.officialVault(), address(officialVault));
        assertEq(curve.officialDeadline(), officialVault.deadline());
        assertEq(curve.platformBps(), 500);
        assertEq(curve.issuer(), issuer);
        assertEq(factory.launchCount(), 2);
        assertEq(factory.launchedTokens(1), token);

        uint256 before = officialVault.reserve();
        vm.prank(bob);
        curve.buy{value: 1_000e18}(0, bob);
        assertEq(officialVault.reserve() - before, 1.5e18);
    }

    function test_ValueMustMatchFeePlusDevBuy() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BadValue.selector, 1e18 + 5e18, 1e18));
        factory.launchOfficial{value: 1e18}("X", "X", meta, 5e18);
        _launchOfficial();
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(LaunchFactory.BadValue.selector, 1e18, 0));
        factory.launch{value: 0}("X", "X", meta, 0);
    }

    function test_ConstructorRejectsBadArgs() public {
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(address(0), address(deployer), address(sink), owner, P, G, 1e18);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(POOL_MANAGER, address(0), address(sink), owner, P, G, 1e18);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(POOL_MANAGER, address(deployer), address(0), owner, P, G, 1e18);
        vm.expectRevert(LaunchFactory.ZeroAddress.selector);
        new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), address(0), P, G, 1e18);
        vm.expectRevert(LaunchFactory.BadEconomics.selector);
        new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), owner, 0, G, 1e18);
        vm.expectRevert(LaunchFactory.BadEconomics.selector);
        new LaunchFactory(POOL_MANAGER, address(deployer), address(sink), owner, P, 0, 1e18);
    }
}
