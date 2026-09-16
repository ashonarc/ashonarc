// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PlatformSink
 * @notice Fixed destination for the platform slice of launch fees.
 *
 * Every RedemptionVault hard-codes this contract's address as an immutable, so
 * the address can never change for tokens already launched. Putting an owner
 * behind it means the *controller* can still be rotated — to a fresh key, a
 * multisig, or a splitter — without touching a single deployed vault.
 *
 * Deliberately minimal: it holds native USDC, pays it out on the owner's instruction,
 * and hands over ownership. Nothing else.
 */
contract PlatformSink {
    error NotOwner();
    error ZeroAddress();
    error PayoutFailed();

    address public owner;
    address public pendingOwner;

    event Withdrawn(address indexed to, uint256 amount);
    event OwnershipTransferStarted(address indexed from, address indexed to);
    event OwnershipTransferred(address indexed from, address indexed to);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    receive() external payable {}

    function withdraw(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit Withdrawn(to, amount);
    }

    function withdrawAll(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = address(this).balance;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert PayoutFailed();
        emit Withdrawn(to, amount);
    }

    /// @notice Two-step handover: a typo in `newOwner` cannot brick the sink.
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        address previous = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, owner);
    }
}
