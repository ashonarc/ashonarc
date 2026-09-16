// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PlatformSink} from "../contracts/PlatformSink.sol";
import {CurveDeployer} from "../contracts/CurveDeployer.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";
import {LaunchpadLens} from "../contracts/LaunchpadLens.sol";

/**
 * Deploys Sink -> CurveDeployer -> Factory -> Lens and launches the official token.
 *
 * env: PRIVATE_KEY, POOL_MANAGER, PLATFORM_SINK_OWNER,
 *      VIRTUAL_QUOTE, GRADUATION_THRESHOLD, LAUNCH_FEE   (18-decimal native USDC)
 *      OFFICIAL_NAME, OFFICIAL_SYMBOL, OFFICIAL_DEV_BUY,
 *      OFFICIAL_LOGO, OFFICIAL_DESCRIPTION, OFFICIAL_SOCIALS (optional)
 *      I_MEAN_IT=true to allow the production symbol.
 *      SKIP_OFFICIAL=true deploys the four infrastructure contracts only; the
 *      official token is then launched later with LaunchOfficial.s.sol.
 */
contract DeployArc is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address sender = vm.addr(pk);
        bool skipOfficial = vm.envOr("SKIP_OFFICIAL", false);
        string memory symbol = skipOfficial ? "" : vm.envString("OFFICIAL_SYMBOL");
        if (!skipOfficial && _isProdSymbol(symbol) && !vm.envOr("I_MEAN_IT", false)) {
            revert("refusing to launch the production symbol without I_MEAN_IT=true");
        }

        uint256 devBuy = vm.envOr("OFFICIAL_DEV_BUY", uint256(0));
        uint256 launchFee = vm.envUint("LAUNCH_FEE");

        vm.startBroadcast(pk);
        PlatformSink sink = new PlatformSink(vm.envAddress("PLATFORM_SINK_OWNER"));
        CurveDeployer deployer = new CurveDeployer();
        LaunchFactory factory = new LaunchFactory(
            vm.envAddress("POOL_MANAGER"),
            address(deployer),
            address(sink),
            sender,
            vm.envUint("VIRTUAL_QUOTE"),
            vm.envUint("GRADUATION_THRESHOLD"),
            launchFee
        );
        LaunchpadLens lens = new LaunchpadLens(address(factory));
        if (skipOfficial) {
            vm.stopBroadcast();
            console2.log("PlatformSink   ", address(sink));
            console2.log("CurveDeployer  ", address(deployer));
            console2.log("LaunchFactory  ", address(factory));
            console2.log("LaunchpadLens  ", address(lens));
            console2.log("official token  (not launched; run LaunchOfficial.s.sol)");
            return;
        }
        (address token, address curve, address vault) = factory.launchOfficial{value: launchFee + devBuy}(
            vm.envString("OFFICIAL_NAME"),
            symbol,
            LaunchFactory.Metadata({
                logo: vm.envOr("OFFICIAL_LOGO", string("")),
                description: vm.envOr("OFFICIAL_DESCRIPTION", string("")),
                socials: vm.envOr("OFFICIAL_SOCIALS", string(""))
            }),
            devBuy
        );
        vm.stopBroadcast();

        console2.log("PlatformSink   ", address(sink));
        console2.log("CurveDeployer  ", address(deployer));
        console2.log("LaunchFactory  ", address(factory));
        console2.log("LaunchpadLens  ", address(lens));
        console2.log("official token ", token);
        console2.log("official curve ", curve);
        console2.log("official vault ", vault);
    }

    function _isProdSymbol(string memory s) private pure returns (bool) {
        bytes32 h = keccak256(bytes(s));
        return h == keccak256("ASH") || h == keccak256("ash") || h == keccak256("Ash");
    }
}
