// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IRoles} from "../interfaces/IRoles.sol";
import {OivInfraConstants} from "../OivInfraConstants.sol";

/// @title  OivStackWiring
/// @author kpk
/// @notice The Zodiac Roles Modifier wiring `KpkOivFactory` performs on every fund it deploys.
///
/// @dev    ## Why this is a linked library
///
///         `KpkOivFactory` had 125 bytes of EIP-170 headroom once `deployNavFund` was added — a
///         position it cannot ship from, since the factory's address is inside every Avatar Safe's
///         `setup()` initializer and so a single added byte moves every fund address on 19 chains.
///         Moving the wiring out is what buys the headroom back, and it keeps ONE copy of the wiring
///         shared by `deployOiv`, `deployStack` and `deployNavFund` rather than letting a second
///         factory drift from the first.
///
///         Its functions are `external`, so Solidity emits DELEGATECALLs from the factory rather than
///         inlining them. That is the whole point — the code lives in this contract's deployed bytecode
///         instead of the factory's — and it is also what makes the extraction behaviour-preserving:
///         under DELEGATECALL `address(this)` is still the factory, so every `IRoles` call below
///         arrives with `msg.sender == factory`, exactly as before. The Roles Modifiers are owned by
///         the factory at this point in the deployment and would reject any other caller.
///
///         This library touches NO storage. Everything it needs is an argument or a constant.
///
///         ## Deployment constraint
///
///         The factory's creation code embeds this library's address, so the library MUST sit at the
///         same address on every chain or the factory itself lands at a different address per chain.
///         It takes no constructor arguments and is deployed through the canonical CREATE2 factory for
///         exactly that reason, and the address is then pinned in `foundry.toml`'s `[libraries]` so
///         every build links against the same one.
library OivStackWiring {
    /// @dev bytes32("MANAGER") — the role the Manager Safe and sub modifier hold on the exec modifier.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 internal constant MANAGER_ROLE = bytes32("MANAGER");

    /// @dev `multiSend(bytes)`. Both MultiSend variants share it, but the unwrap adapter is keyed on
    ///      the `(target, selector)` pair, so each still needs its own registration.
    bytes4 internal constant MULTI_SEND_SELECTOR = bytes4(keccak256("multiSend(bytes)"));

    /// @notice Wires the exec (primary) Roles Modifier and hands it to `finalOwner`.
    /// @dev    After this call: avatar = target = `avatarSafe`; the Manager Safe holds MANAGER; the sub
    ///         modifier is an enabled nested module whose default role is MANAGER, so calls it routes
    ///         inherit the role automatically.
    ///
    ///         `transferOwnership` is last, and must stay last: `setTransactionUnwrapper` is
    ///         owner-only, so once the modifier belongs to the Security Council the adapters could
    ///         only be registered by a multisig transaction.
    function wireExec(address mod, address avatarSafe, address managerSafe, address subMod, address finalOwner)
        external
    {
        bytes32[] memory roleKeys = new bytes32[](1);
        roleKeys[0] = MANAGER_ROLE;
        bool[] memory memberOf = new bool[](1);
        memberOf[0] = true;

        IRoles(mod).assignRoles(managerSafe, roleKeys, memberOf);
        IRoles(mod).enableModule(subMod);
        IRoles(mod).setDefaultRole(subMod, MANAGER_ROLE);
        IRoles(mod).assignRoles(subMod, roleKeys, memberOf);
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(avatarSafe);
        _registerMultiSendUnwrappers(mod);
        IRoles(mod).transferOwnership(finalOwner);
    }

    /// @notice Wires the sub Roles Modifier and hands it to the Manager Safe.
    /// @dev    Target is the exec modifier, not the Avatar Safe: calls route through the exec layer so
    ///         they are permission-checked there rather than bypassing it.
    function wireSub(address mod, address avatarSafe, address execMod, address managerSafe) external {
        IRoles(mod).setAvatar(avatarSafe);
        IRoles(mod).setTarget(execMod);
        _registerMultiSendUnwrappers(mod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @notice Wires the manager Roles Modifier and hands it to the Manager Safe.
    /// @dev    Avatar and target are both the Manager Safe — this modifier guards actions originating
    ///         from the Manager Safe itself.
    function wireManager(address mod, address managerSafe) external {
        IRoles(mod).setAvatar(managerSafe);
        IRoles(mod).setTarget(managerSafe);
        _registerMultiSendUnwrappers(mod);
        IRoles(mod).transferOwnership(managerSafe);
    }

    /// @dev Registers the Zodiac MultiSendUnwrapper against both Safe MultiSend contracts. A Roles
    ///      Modifier permission-checks one call at a time, so without an unwrap adapter a batched
    ///      `multiSend` arrives as a single opaque delegatecall it cannot decompose and rejects
    ///      outright. `internal`, so it inlines into the three functions above rather than costing a
    ///      second DELEGATECALL per modifier.
    function _registerMultiSendUnwrappers(address mod) internal {
        IRoles(mod)
            .setTransactionUnwrapper(
                OivInfraConstants.MULTI_SEND, MULTI_SEND_SELECTOR, OivInfraConstants.MULTISEND_UNWRAPPER
            );
        IRoles(mod)
            .setTransactionUnwrapper(
                OivInfraConstants.MULTI_SEND_CALLS_ONLY, MULTI_SEND_SELECTOR, OivInfraConstants.MULTISEND_UNWRAPPER
            );
    }
}
