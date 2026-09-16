// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "./FullMath.sol";

interface IRedeemableToken {
    function burnFrom(address account, uint256 amount) external;
    function totalSupply() external view returns (uint256);
}

/**
 * @title RedemptionVault
 * @notice One pool per token. Native USDC arrives from the token's bonding curve
 * (trading fees, snipe tax, post-graduation LP fees); holders burn tokens to
 * withdraw their pro-rata share until the deadline; afterwards the issuer sweeps
 * whatever is left, once.
 *
 * Deliberately absent: owner, pause, upgrade, any admin withdrawal, and any
 * reference to the curve or factory. The pool cannot be redirected or drained
 * by anyone, including us.
 */
contract RedemptionVault {
    error ZeroAddress();
    error ZeroAmount();
    error DeadlineInPast();
    error WindowClosed();
    error WindowOpen();
    error QuoteExpired();
    error Slippage();
    error ZeroPayout();
    error SupplyMismatch();
    error NotIssuer();
    error AlreadySwept();
    error TransferFailed();
    error Reentrancy();

    IRedeemableToken public immutable token;
    uint256 public immutable deadline;
    address public immutable issuer;

    /// @dev Tracked explicitly rather than read from `balance`, so value that
    /// arrives outside `fund` (a self-destruct, say) cannot inflate the quote.
    uint256 public reserve;
    uint256 public totalFunded;
    uint256 public totalRedeemed;
    uint256 public totalBurned;
    bool public residualSwept;
    uint256 public residualPaid;

    uint256 private _lock = 1;

    event Funded(address indexed from, uint256 amount);
    event Redeemed(address indexed holder, address indexed receiver, uint256 burned, uint256 paid);
    event ResidualWithdrawn(address indexed receiver, uint256 amount);

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address token_, uint256 deadline_, address issuer_) {
        if (token_ == address(0) || issuer_ == address(0)) revert ZeroAddress();
        if (deadline_ <= block.timestamp) revert DeadlineInPast();
        token = IRedeemableToken(token_);
        deadline = deadline_;
        issuer = issuer_;
    }

    /// @notice Anyone may fund; it only ever raises the backing. Refused once the
    /// issuer has swept, because nobody could withdraw it afterwards.
    receive() external payable {
        _fund();
    }

    function fund() external payable {
        _fund();
    }

    function _fund() private {
        if (residualSwept) revert AlreadySwept();
        reserve += msg.value;
        totalFunded += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    function isOpen() public view returns (bool) {
        return block.timestamp < deadline;
    }

    /// @notice USDC (18 decimals) paid for burning `q` tokens right now.
    function previewRedeem(uint256 q) public view returns (uint256) {
        if (!isOpen()) return 0;
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        return FullMath.mulDiv(q, reserve, supply);
    }

    /// @notice Backing per whole token, scaled by 1e18.
    function backingPerToken() external view returns (uint256) {
        uint256 supply = token.totalSupply();
        if (supply == 0) return 0;
        return FullMath.mulDiv(reserve, 1e18, supply);
    }

    /**
     * @notice Burn `q` tokens, receive `q / totalSupply` of the reserve.
     * @param minOut Reverts if the payout is below this.
     * @param quoteDeadline Reverts if mined after this timestamp.
     * @param receiver Where the USDC goes; lets a holder route around an address
     * that cannot receive value.
     */
    function redeem(uint256 q, uint256 minOut, uint256 quoteDeadline, address receiver)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (!isOpen()) revert WindowClosed();
        if (block.timestamp > quoteDeadline) revert QuoteExpired();
        if (receiver == address(0)) revert ZeroAddress();
        if (q == 0) revert ZeroAmount();

        uint256 supplyBefore = token.totalSupply();
        out = FullMath.mulDiv(q, reserve, supplyBefore);
        if (out == 0) revert ZeroPayout();
        if (out < minOut) revert Slippage();

        reserve -= out;
        totalRedeemed += out;
        totalBurned += q;

        token.burnFrom(msg.sender, q);
        if (token.totalSupply() != supplyBefore - q) revert SupplyMismatch();

        _send(receiver, out);
        emit Redeemed(msg.sender, receiver, q, out);
    }

    /// @notice After the deadline the issuer takes the whole balance, once. The
    /// flag, not the balance, is what makes it once: value forced in later
    /// cannot reopen it.
    function withdrawResidual(address receiver) external nonReentrant {
        if (msg.sender != issuer) revert NotIssuer();
        if (isOpen()) revert WindowOpen();
        if (residualSwept) revert AlreadySwept();
        if (receiver == address(0)) revert ZeroAddress();

        residualSwept = true;
        uint256 amount = address(this).balance;
        reserve = 0;
        residualPaid = amount;
        _send(receiver, amount);
        emit ResidualWithdrawn(receiver, amount);
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
