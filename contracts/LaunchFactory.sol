// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {LaunchToken} from "./LaunchToken.sol";
import {RedemptionVault} from "./RedemptionVault.sol";
import {BondingCurve} from "./BondingCurve.sol";
import {CurveDeployer} from "./CurveDeployer.sol";

/**
 * @title LaunchFactory
 * @notice One transaction: token, redemption vault, bonding curve, pool claimed,
 * optional opening buy. The economics are fixed here so no issuer can pick a
 * shorter window or a larger cut, and the owner's only power is to launch the
 * official token once.
 */
contract LaunchFactory {
    error NotOwner();
    error ZeroAddress();
    error BadEconomics();
    error AlreadyLaunched();
    error OfficialNotLaunched();
    error BadValue(uint256 expected, uint256 provided);
    error TransferFailed();
    error Reentrancy();

    struct Metadata {
        string logo;
        string description;
        string socials;
    }

    uint256 public constant WINDOW = 30 days;
    uint16 public constant POOL_BPS = 8_500;
    uint16 public constant ISSUER_BPS = 1_000;
    uint16 public constant PLATFORM_BPS = 500;
    uint16 public constant OFFICIAL_POOL_BPS = 9_000;
    uint16 public constant OFFICIAL_PLATFORM_BPS = 0;

    IPoolManager public immutable poolManager;
    /// @dev Holds the curve's creation code so this contract stays under 24 KB.
    CurveDeployer public immutable curveDeployer;
    address public immutable platformSink;
    /// @notice Set at deployment, immutable afterwards. Same bytecode serves the
    /// testnet (tiny numbers) and mainnet (real ones).
    uint256 public immutable virtualQuote;
    uint256 public immutable graduationThreshold;
    uint256 public immutable launchFee;

    address public owner;
    address public officialToken;
    address public officialVault;
    uint256 public officialDeadline;

    address[] public launchedTokens;
    mapping(address token => address) public curveOf;
    mapping(address token => address) public vaultOf;
    mapping(address token => Metadata) private _metadata;

    uint256 private _lock = 1;

    event Launched(
        address indexed token,
        address indexed curve,
        address indexed vault,
        address issuer,
        uint256 deadline,
        uint256 devBuy,
        bool official
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(
        address poolManager_,
        address curveDeployer_,
        address platformSink_,
        address owner_,
        uint256 virtualQuote_,
        uint256 graduationThreshold_,
        uint256 launchFee_
    ) {
        if (
            poolManager_ == address(0) || curveDeployer_ == address(0) || platformSink_ == address(0)
                || owner_ == address(0)
        ) revert ZeroAddress();
        if (virtualQuote_ == 0 || graduationThreshold_ == 0) revert BadEconomics();
        poolManager = IPoolManager(poolManager_);
        curveDeployer = CurveDeployer(curveDeployer_);
        platformSink = platformSink_;
        owner = owner_;
        virtualQuote = virtualQuote_;
        graduationThreshold = graduationThreshold_;
        launchFee = launchFee_;
    }

    function launchCount() external view returns (uint256) {
        return launchedTokens.length;
    }

    function metadataOf(address token) external view returns (Metadata memory) {
        return _metadata[token];
    }

    /// @notice The official token: no platform slice, and its vault receives the
    /// 5% slice of every later launch until its own deadline. Once.
    function launchOfficial(string calldata name, string calldata symbol, Metadata calldata meta, uint256 devBuy)
        external
        payable
        onlyOwner
        nonReentrant
        returns (address token, address curve, address vault)
    {
        if (officialVault != address(0)) revert AlreadyLaunched();
        (token, curve, vault) = _launch(name, symbol, meta, devBuy, OFFICIAL_POOL_BPS, OFFICIAL_PLATFORM_BPS, true);
        officialToken = token;
        officialVault = vault;
        officialDeadline = RedemptionVault(payable(vault)).deadline();
    }

    /// @notice Anyone. `msg.sender` is the issuer: 10% of fees, the residual
    /// after the deadline, and a tax-free opening buy. Send `launchFee + devBuy`.
    function launch(string calldata name, string calldata symbol, Metadata calldata meta, uint256 devBuy)
        external
        payable
        nonReentrant
        returns (address token, address curve, address vault)
    {
        if (officialVault == address(0)) revert OfficialNotLaunched();
        return _launch(name, symbol, meta, devBuy, POOL_BPS, PLATFORM_BPS, false);
    }

    function _launch(
        string calldata name,
        string calldata symbol,
        Metadata calldata meta,
        uint256 devBuy,
        uint16 poolBps,
        uint16 platformBps,
        bool official
    ) private returns (address token, address curve, address vault) {
        if (msg.value != launchFee + devBuy) revert BadValue(launchFee + devBuy, msg.value);

        LaunchToken t = new LaunchToken(name, symbol);
        RedemptionVault v = new RedemptionVault(address(t), block.timestamp + WINDOW, msg.sender);
        BondingCurve c = BondingCurve(payable(curveDeployer.deploy(_config(address(t), address(v), poolBps, platformBps, official))));
        t.transfer(address(c), t.TOTAL_SUPPLY());
        // Claim the Uniswap pool key now, before anyone can squat on it.
        c.initializePool();

        token = address(t);
        curve = address(c);
        vault = address(v);
        curveOf[token] = curve;
        vaultOf[token] = vault;
        _metadata[token] = meta;
        launchedTokens.push(token);

        if (launchFee != 0) {
            (bool ok,) = platformSink.call{value: launchFee}("");
            if (!ok) revert TransferFailed();
        }
        // Last, so a graduation triggered by a large opening buy finds a fully wired curve.
        if (devBuy != 0) c.buy{value: devBuy}(0, msg.sender);

        emit Launched(token, curve, vault, msg.sender, v.deadline(), devBuy, official);
    }

    function _config(address token, address vault, uint16 poolBps, uint16 platformBps, bool official)
        private
        view
        returns (BondingCurve.Config memory)
    {
        return BondingCurve.Config({
            factory: address(this),
            token: token,
            vault: vault,
            issuer: msg.sender,
            officialVault: official ? address(0) : officialVault,
            officialDeadline: official ? 0 : officialDeadline,
            platformSink: platformSink,
            poolManager: address(poolManager),
            virtualQuote: virtualQuote,
            graduationThreshold: graduationThreshold,
            poolBps: poolBps,
            issuerBps: ISSUER_BPS,
            platformBps: platformBps
        });
    }
}
