// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice Minimal burnable ERC-20 with a switch for dishonest burns.
/// `honest = false` makes burnFrom move tokens without reducing totalSupply,
/// which is exactly the failure RedemptionVault must detect.
contract MockToken {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    bool public honest = true;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(uint256 supply, address to) {
        totalSupply = supply;
        balanceOf[to] = supply;
    }

    function setHonest(bool v) external {
        honest = v;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        return true;
    }

    function burnFrom(address account, uint256 value) external {
        uint256 allowed = allowance[account][msg.sender];
        require(allowed >= value, "allowance");
        allowance[account][msg.sender] = allowed - value;
        balanceOf[account] -= value;
        if (honest) {
            totalSupply -= value;
        } else {
            balanceOf[address(0xdead)] += value;
        }
    }
}

/// @notice Refuses every incoming transfer, to exercise the payout-failed path.
contract RejectEth {
    receive() external payable {
        revert("no");
    }
}
