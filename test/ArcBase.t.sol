// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {PlatformSink} from "../contracts/PlatformSink.sol";
import {LaunchToken} from "../contracts/LaunchToken.sol";
import {RedemptionVault} from "../contracts/RedemptionVault.sol";
import {BondingCurve} from "../contracts/BondingCurve.sol";
import {CurveDeployer} from "../contracts/CurveDeployer.sol";

/// @notice Shared fixture: Uniswap's real PoolManager bytecode (pulled from Arc
/// mainnet) etched at its mainnet address, a swap router, a platform sink, and
/// helpers that build a token/vault/curve trio the way the factory will.
abstract contract ArcBase is Test {
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint256 constant P = 5_000e18;
    uint256 constant G = 8_000e18;
    uint256 constant SUPPLY = 1_000_000_000e18;

    IPoolManager manager = IPoolManager(POOL_MANAGER);
    PoolSwapTest router;
    PlatformSink sink;
    CurveDeployer deployer;

    address platformOwner = makeAddr("platformOwner");
    address issuer = makeAddr("issuer");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    function setUp() public virtual {
        vm.etch(POOL_MANAGER, vm.parseBytes(vm.readFile("test/bin/PoolManager.hex")));
        vm.label(POOL_MANAGER, "PoolManager");
        router = new PoolSwapTest(manager);
        sink = new PlatformSink(platformOwner);
        deployer = new CurveDeployer();
        vm.deal(issuer, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);
        vm.deal(carol, 1_000_000 ether);
        // Arc's clock: the launch happens "now"; buys in most tests come later.
        vm.warp(1_800_000_000);
    }

    struct Trio {
        LaunchToken token;
        RedemptionVault vault;
        BondingCurve curve;
    }

    /// @dev Mirrors LaunchFactory._launch without the factory: this test
    /// contract plays the factory, so `msg.sender` inside the curve's
    /// constructor is us.
    function _deployTrio(
        address issuer_,
        address officialVault,
        uint256 officialDeadline,
        uint256 graduationThreshold,
        uint16 poolBps,
        uint16 platformBps
    ) internal returns (Trio memory t) {
        t.token = new LaunchToken("Rehearsal", "REHRSL");
        t.vault = new RedemptionVault(address(t.token), block.timestamp + 30 days, issuer_);
        t.curve = new BondingCurve(
            BondingCurve.Config({
                factory: address(this),
                token: address(t.token),
                vault: address(t.vault),
                issuer: issuer_,
                officialVault: officialVault,
                officialDeadline: officialDeadline,
                platformSink: address(sink),
                poolManager: POOL_MANAGER,
                virtualQuote: P,
                graduationThreshold: graduationThreshold,
                poolBps: poolBps,
                issuerBps: 1_000,
                platformBps: platformBps
            })
        );
        t.token.transfer(address(t.curve), SUPPLY);
        t.curve.initializePool();
    }

    function _thirdParty(address officialVault, uint256 officialDeadline) internal returns (Trio memory) {
        return _deployTrio(issuer, officialVault, officialDeadline, G, 8_500, 500);
    }

    function _official() internal returns (Trio memory) {
        return _deployTrio(issuer, address(0), 0, G, 9_000, 0);
    }

    /// @dev Past the snipe window.
    function _later() internal {
        vm.warp(block.timestamp + 10);
    }
}
