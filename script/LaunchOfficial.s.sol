// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LaunchFactory} from "../contracts/LaunchFactory.sol";

/**
 * Launches the official token on an already deployed factory.
 *
 * env: PRIVATE_KEY (the factory owner), FACTORY,
 *      OFFICIAL_NAME, OFFICIAL_SYMBOL, OFFICIAL_DEV_BUY,
 *      OFFICIAL_LOGO, OFFICIAL_DESCRIPTION, OFFICIAL_SOCIALS (optional)
 *      I_MEAN_IT=true to allow the production symbol.
 */
contract LaunchOfficial is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        LaunchFactory factory = LaunchFactory(vm.envAddress("FACTORY"));
        string memory symbol = vm.envString("OFFICIAL_SYMBOL");
        if (_isProdSymbol(symbol) && !vm.envOr("I_MEAN_IT", false)) {
            revert("refusing to launch the production symbol without I_MEAN_IT=true");
        }
        require(factory.owner() == vm.addr(pk), "PRIVATE_KEY is not the factory owner");
        require(factory.officialToken() == address(0), "official token already launched");

        uint256 devBuy = vm.envOr("OFFICIAL_DEV_BUY", uint256(0));
        uint256 launchFee = factory.launchFee();

        vm.startBroadcast(pk);
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

        console2.log("official token ", token);
        console2.log("official curve ", curve);
        console2.log("official vault ", vault);
    }

    function _isProdSymbol(string memory s) private pure returns (bool) {
        bytes32 h = keccak256(bytes(s));
        return h == keccak256("ASH") || h == keccak256("ash") || h == keccak256("Ash");
    }
}
