// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

/// @notice Testnet only: Arc testnet has no Uniswap V4, so deploy our own
/// PoolManager and a swap router. Compile with the v4 profile so PoolManager
/// fits under EIP-170:
///   FOUNDRY_PROFILE=v4 forge script script/DeployTestnetV4.s.sol --rpc-url arc_testnet --broadcast --legacy --with-gas-price 25gwei
contract DeployTestnetV4 is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        PoolManager pm = new PoolManager(vm.addr(pk));
        PoolSwapTest router = new PoolSwapTest(pm);
        vm.stopBroadcast();
        console2.log("PoolManager  ", address(pm));
        console2.log("PoolSwapTest ", address(router));
    }
}
