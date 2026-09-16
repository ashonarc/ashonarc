// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BondingCurve} from "./BondingCurve.sol";

/**
 * @title CurveDeployer
 * @notice Deploys BondingCurve instances for the factory. It exists for one
 * reason: a contract that `new`s another one carries that contract's whole
 * creation code, and the curve's alone puts the factory over the 24 KB limit.
 * Anyone may call this; a curve nobody registered in the factory is invisible
 * to the lens and holds nothing of ours.
 */
contract CurveDeployer {
    function deploy(BondingCurve.Config calldata config) external returns (address) {
        return address(new BondingCurve(config));
    }
}
