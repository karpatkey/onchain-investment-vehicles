// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {KpkOivFactory} from "./KpkOivFactory.sol";
import {KpkSharesNav} from "./KpkSharesNav.sol";
import {IKpkTimelockDeployer, TimelockParams} from "./interfaces/IKpkTimelockDeployer.sol";

/// @title  KpkSharesNavFactory
/// @author KPK
/// @notice Deploys a NAV-priced fund on a single chain: the five-contract operational stack through the
///         live `KpkOivFactory.deployStack`, then a `KpkSharesNav` ERC-1967 proxy whose portfolio safe is
///         that stack's Avatar Safe.
///         Composes the live factory instead of extending it: `KpkOivFactory` is deployed on every wired
///         chain, an edit to it moves its CREATE2 address and re-rolls that deployment, and it has little
///         EIP-170 headroom.
///
///         APPROVAL GAP. The Avatar Safe grants the fund no token allowance in the deploy transaction.
///         `deployStack` disables the live factory's Avatar module before it returns and this contract is
///         not an Avatar module, so nothing here can execute `approve` from the Avatar Safe.
///         `KpkOivFactory.deployShares` takes the same posture. Consequences:
///         - Redemption settlement pulls the payout from the Avatar Safe (`safeTransferFrom(portfolioSafe,
///           …)` in `KpkSharesNav`), so it reverts until the admin grants `approve(proxy, max)` for each
///           redeemable asset through the exec Roles Modifier.
///         - `syncDepositsEnabled` starts false, so an investor receives shares only when the operator
///           settles their subscription request. Grant the approvals before settling the first one.
///         pinned: test/KpkSharesNavFactory.t.sol::test_approvals_startAtZeroAndAdminGrantsThroughExecModifier
///
///         Permissionless. `msg.sender` is hashed into every fund's salt (see `_fundSalt`).
contract KpkSharesNavFactory is ReentrancyGuard {
    // ── Immutables ─────────────────────────────────────────────────────────────

    /// @notice The live factory that deploys each fund's operational stack.
    KpkOivFactory public immutable factory;

    /// @notice The `KpkSharesNav` implementation every fund proxy delegates to.
    address public immutable kpkSharesNavMastercopy;

    /// @notice `factory.timelockDeployer()`, read at construction, so the shares timelock comes from the
    ///         deployer the live factory uses for exec timelocks.
    address public immutable timelockDeployer;

    // ── Structs ────────────────────────────────────────────────────────────────

    /// @notice Full configuration of a NAV fund.
    struct NavFundConfig {
        /// @notice Manager Safe signers; validated by the live factory.
        KpkOivFactory.SafeConfig managerSafe;
        /// @notice Caller-chosen salt, hashed together with every other field (see `_fundSalt`).
        uint256 salt;
        /// @notice Owner of the exec Roles Modifier and holder of the fund's `DEFAULT_ADMIN_ROLE`. Each
        ///         is replaced by its timelock when that timelock's `minDelay` is non-zero.
        address admin;
        /// @notice Fund initialization parameters. `.admin` and `.safe` are overwritten with this
        ///         contract and the deployed Avatar Safe, so they are excluded from the salt.
        KpkSharesNav.ConstructorParams sharesParams;
        /// @notice Assets listed on the fund beyond `sharesParams.asset`.
        KpkOivFactory.AssetConfig[] additionalAssets;
        /// @notice Passed through to `deployStack`; owns the exec Roles Modifier when `minDelay != 0`.
        TimelockParams execTimelock;
        /// @notice Holds `DEFAULT_ADMIN_ROLE` on the fund INSTEAD of `admin` when `minDelay != 0`.
        TimelockParams sharesTimelock;
    }

    /// @notice Addresses of a deployed NAV fund. A timelock that was not configured is `address(0)`.
    struct NavFundInstance {
        address avatarSafe;
        address managerSafe;
        address execRolesModifier;
        address subRolesModifier;
        address managerRolesModifier;
        address kpkSharesNavImpl;
        address kpkSharesNavProxy;
        address execTimelock;
        address sharesTimelock;
    }

    // ── State ──────────────────────────────────────────────────────────────────

    /// @notice Number of funds deployed through `deployNavFund`.
    uint256 public navFundCount;

    /// @notice Fund instances indexed by deployment order (0-based).
    mapping(uint256 => NavFundInstance) public navFunds;

    // ── Events and errors ──────────────────────────────────────────────────────

    /// @notice Emitted once per `deployNavFund`.
    event NavFundDeployed(uint256 indexed id, NavFundInstance instance);

    /// @notice A required address is zero, or `admin` is this contract.
    error ZeroAddress();

    /// @notice A constructor dependency has no code.
    error InvalidMastercopy();

    /// @notice `additionalAssets` repeats an asset or relists `sharesParams.asset`.
    error DuplicateAsset();

    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @param factory_                 The live `KpkOivFactory`.
    /// @param kpkSharesNavMastercopy_  The `KpkSharesNav` implementation.
    constructor(address factory_, address kpkSharesNavMastercopy_) {
        if (factory_ == address(0) || kpkSharesNavMastercopy_ == address(0)) revert ZeroAddress();
        if (factory_.code.length == 0 || kpkSharesNavMastercopy_.code.length == 0) revert InvalidMastercopy();
        factory = KpkOivFactory(factory_);
        kpkSharesNavMastercopy = kpkSharesNavMastercopy_;
        timelockDeployer = KpkOivFactory(factory_).timelockDeployer();
    }

    // ── Entry points ───────────────────────────────────────────────────────────

    /// @notice Deploys the operational stack, the fund proxy and, when configured, the shares timelock,
    ///         then hands the fund's roles to their holders.
    /// @dev    Leaves the Avatar Safe with no allowance to the fund; see the contract-level APPROVAL GAP.
    ///         Reverts on the same `config` from the same caller a second time, because the live factory
    ///         refuses a stack that already exists.
    ///         pinned: test/KpkSharesNavFactory.t.sol::test_callerIsolation_disjointAddressesAndReplayReverts
    /// @param  config   Fund configuration.
    /// @return instance Addresses of the deployed contracts, also stored in `navFunds[navFundCount - 1]`.
    function deployNavFund(NavFundConfig calldata config)
        external
        nonReentrant
        returns (NavFundInstance memory instance)
    {
        _validate(config);

        // Reserved before any external call.
        uint256 id = navFundCount++;

        bytes32 fundSalt = _fundSalt(config, msg.sender);
        KpkOivFactory.StackInstance memory stack = factory.deployStack(_stackConfig(config, fundSalt));

        KpkSharesNav.ConstructorParams memory params = config.sharesParams;
        params.safe = stack.avatarSafe;
        params.admin = address(this);

        // Initialization data is in the constructor, so the proxy is initialized in the transaction that
        // creates it.
        address proxy = address(
            new ERC1967Proxy{salt: fundSalt}(kpkSharesNavMastercopy, abi.encodeCall(KpkSharesNav.initialize, (params)))
        );
        KpkSharesNav fund = KpkSharesNav(proxy);
        bytes32 operatorRole = fund.OPERATOR();

        uint256 len = config.additionalAssets.length;
        if (len != 0) {
            fund.grantRole(operatorRole, address(this));
            for (uint256 i = 0; i < len; i++) {
                KpkOivFactory.AssetConfig calldata a = config.additionalAssets[i];
                fund.updateAsset(a.asset, a.canDeposit, a.canRedeem);
            }
            fund.revokeRole(operatorRole, address(this));
        }

        fund.grantRole(operatorRole, stack.managerSafe);

        // The timelock is granted the role ALONE: `admin` keeping it would bypass the delay.
        // pinned: test/KpkSharesNavFactory.t.sol::test_roleHandover_withTimelocks
        address sharesTimelock;
        if (config.sharesTimelock.minDelay != 0) {
            sharesTimelock = IKpkTimelockDeployer(timelockDeployer).deploySharesTimelock(proxy, config.sharesTimelock);
            fund.grantRole(DEFAULT_ADMIN_ROLE, sharesTimelock);
        } else {
            fund.grantRole(DEFAULT_ADMIN_ROLE, config.admin);
        }
        fund.renounceRole(DEFAULT_ADMIN_ROLE, address(this));

        instance = NavFundInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesNavImpl: kpkSharesNavMastercopy,
            kpkSharesNavProxy: proxy,
            execTimelock: stack.execTimelock,
            sharesTimelock: sharesTimelock
        });
        navFunds[id] = instance;
        emit NavFundDeployed(id, instance);
    }

    /// @notice Predicts the addresses `deployNavFund(config)` produces when called by `caller`.
    /// @dev    Runs this contract's `_validate`, and the live factory's stack validation through
    ///         `predictStackAddresses`. It does not run the checks inside `KpkSharesNav.initialize` or
    ///         `updateAsset` (TTLs, fee caps, NAV calculator and asset registration), so a config that
    ///         predicts can still revert in `deployNavFund`.
    ///         pinned: test/KpkSharesNavFactory.t.sol::test_deployMatchesPrediction_noTimelocks
    ///         pinned: test/KpkSharesNavFactory.t.sol::test_deployMatchesPrediction_withTimelocks
    /// @param  config Fund configuration.
    /// @param  caller Address that would call `deployNavFund`.
    /// @return inst   Predicted addresses.
    function predictNavFund(NavFundConfig calldata config, address caller)
        external
        view
        returns (NavFundInstance memory inst)
    {
        _validate(config);

        bytes32 fundSalt = _fundSalt(config, caller);
        // Called with this contract as the caller, which is who calls `deployStack`.
        KpkOivFactory.StackInstance memory stack =
            factory.predictStackAddresses(_stackConfig(config, fundSalt), address(this));

        KpkSharesNav.ConstructorParams memory params = config.sharesParams;
        params.safe = stack.avatarSafe;
        params.admin = address(this);
        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(kpkSharesNavMastercopy, abi.encodeCall(KpkSharesNav.initialize, (params)))
        );
        address proxy = address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), fundSalt, keccak256(initCode)))))
        );

        inst = NavFundInstance({
            avatarSafe: stack.avatarSafe,
            managerSafe: stack.managerSafe,
            execRolesModifier: stack.execRolesModifier,
            subRolesModifier: stack.subRolesModifier,
            managerRolesModifier: stack.managerRolesModifier,
            kpkSharesNavImpl: kpkSharesNavMastercopy,
            kpkSharesNavProxy: proxy,
            execTimelock: stack.execTimelock,
            sharesTimelock: address(0)
        });
        if (config.sharesTimelock.minDelay != 0) {
            inst.sharesTimelock =
                IKpkTimelockDeployer(timelockDeployer).predictSharesTimelock(proxy, config.sharesTimelock);
        }
    }

    // ── Internal ───────────────────────────────────────────────────────────────

    /// @dev The stack half of `config`. Sub and manager `finalOwner` stay zero: the live factory hands
    ///      both modifiers to the Manager Safe and does not read them.
    function _stackConfig(NavFundConfig calldata config, bytes32 fundSalt)
        internal
        pure
        returns (KpkOivFactory.StackConfig memory s)
    {
        s.managerSafe = config.managerSafe;
        s.execRolesMod.finalOwner = config.admin;
        s.salt = uint256(fundSalt);
        s.execTimelock = config.execTimelock;
    }

    /// @dev Salt for the stack and the fund proxy: `keccak256(abi.encode(caller, config))`, with the
    ///      fields that are overwritten or unread zeroed.
    ///
    ///      `caller` is hashed because this contract is the live factory's caller for every NAV fund, so
    ///      the live factory's own caller-mixing separates nothing between users of this contract.
    ///      pinned: test/KpkSharesNavFactory.t.sol::test_callerIsolation_disjointAddressesAndReplayReverts
    ///
    ///      The full config is bound, following `CcipOivDeployer._effectiveConfig`, so a replay at a
    ///      fund's addresses cannot change its economics or governance. Single chain, so the base asset
    ///      is bound too. pinned: test/KpkSharesNavFactory.t.sol::test_saltBinding_readFieldsMoveAddresses
    ///
    ///      Zeroed, so that configs deploying the same fund land at the same addresses:
    ///      - `sharesParams.admin` / `.safe`: overwritten in `deployNavFund`.
    ///      - a timelock's role arrays when its `minDelay` is zero: no timelock is deployed, so they are
    ///        not read.
    ///      pinned: test/KpkSharesNavFactory.t.sol::test_saltBinding_unreadFieldsMoveNothing
    function _fundSalt(NavFundConfig calldata config, address caller) internal pure returns (bytes32) {
        NavFundConfig memory eff = config;
        eff.sharesParams.admin = address(0);
        eff.sharesParams.safe = address(0);
        if (eff.execTimelock.minDelay == 0) {
            eff.execTimelock.proposers = new address[](0);
            eff.execTimelock.cancellers = new address[](0);
        }
        if (eff.sharesTimelock.minDelay == 0) {
            eff.sharesTimelock.proposers = new address[](0);
            eff.sharesTimelock.cancellers = new address[](0);
        }
        return keccak256(abi.encode(caller, eff));
    }

    /// @dev The live factory validates the stack half and `KpkSharesNav` validates its own parameters.
    ///      This adds:
    ///      - `admin` zero or this contract. As this contract, it would own the exec Roles Modifier while
    ///        this contract has no code path that calls it; and, with no shares timelock, the renounce in
    ///        `deployNavFund` would leave the fund with no `DEFAULT_ADMIN_ROLE` holder.
    ///      - an additional asset equal to the base asset: relisting overwrites the base asset's flags.
    ///      - a repeated additional asset.
    function _validate(NavFundConfig calldata config) internal view {
        if (config.admin == address(0) || config.admin == address(this)) revert ZeroAddress();
        uint256 len = config.additionalAssets.length;
        for (uint256 i = 0; i < len; i++) {
            address asset = config.additionalAssets[i].asset;
            if (asset == config.sharesParams.asset) revert DuplicateAsset();
            for (uint256 j = i + 1; j < len; j++) {
                if (asset == config.additionalAssets[j].asset) revert DuplicateAsset();
            }
        }
    }
}
