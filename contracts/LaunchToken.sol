// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";

/**
 * @title LaunchToken
 * @notice Fixed-supply ERC-20 with burn. The whole supply is minted to the
 * deployer -- the factory -- which hands it to the bonding curve in the same
 * transaction. No owner, no mint, no transfer restrictions: the snipe tax lives
 * on the curve, and the redemption pool needs nothing from the token except
 * `burnFrom` and an honest `totalSupply`.
 */
contract LaunchToken is ERC20, ERC20Burnable {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
