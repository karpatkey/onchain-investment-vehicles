// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISafe} from "./interfaces/ISafe.sol";
import {ISafeProxyFactory} from "./interfaces/ISafeProxyFactory.sol";
import {ISafeModuleSetup} from "./interfaces/ISafeModuleSetup.sol";

/// @title  SafeAdoptionLib
/// @notice The Safe half of `KpkOivFactory`'s deploy-or-adopt logic, extracted so its code lives at
///         its own address instead of inside the factory.
///
/// @dev    WHY THIS IS A LIBRARY AND NOT A MIXIN. `KpkOivFactory` sits against the EIP-170 ceiling;
///         the margin has been low enough to force fixes to be documented rather than implemented.
///         Only `public` / `external` library functions are DELEGATECALLed and therefore removed
///         from the caller's runtime — `internal` ones are inlined and save nothing — so every entry
///         point here is deliberately `public`, and the library must be DEPLOYED and LINKED.
///
///         The consequences of linking, all of which are load-bearing:
///
///         - The library's address is embedded in `KpkOivFactory`'s bytecode, so the factory's
///           CREATE2 address depends on it. Deploy this at a deterministic address on every chain
///           before the factory, or a fund's addresses diverge per chain.
///         - `libraries=` in `foundry.toml` is a compiler input, hashed into the metadata of every
///           contract compiled with it — including this library's own. Pinning an address therefore
///           changes the bytecode that produced it, so the address has to be re-derived and re-pinned
///           until it stops moving. It settles; it is a chain, not a cycle.
///
///         DELEGATECALL semantics are what make the extraction behaviour-preserving: `address(this)`
///         inside these functions is the FACTORY, so `ComponentAdopted` is emitted by the factory and
///         reverts surface with the factory's own error selectors. Nothing here reads factory
///         storage — the four infrastructure addresses are passed in as `SafeInfra` — so the library
///         holds no state and cannot be made to.
library SafeAdoptionLib {
    /// @notice The four Safe v1.4.1 infrastructure addresses the factory holds in storage. Passed in
    ///         rather than read, because a library has no storage of its own to read them from.
    struct SafeInfra {
        address proxyFactory;
        address singleton;
        address moduleSetup;
        address fallbackHandler;
    }

    /// @notice Emitted when a component was already present at its deterministic address and was
    ///         adopted rather than deployed. Emitted BY THE FACTORY, since this runs under
    ///         DELEGATECALL.
    event ComponentAdopted(address indexed component, bytes32 indexed kind);

    /// @notice Thrown when a Safe already at the deterministic address does not match the
    ///         configuration the factory would have deployed there.
    error AdoptedSafeMismatch(address safe);

    /// @dev Safe's module-list sentinel.
    address private constant SENTINEL_MODULES = address(0x1);

    /// @dev `keccak256("guard_manager.guard.address")` — Safe v1.4.1's guard slot.
    uint256 private constant GUARD_STORAGE_SLOT = 0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8;

    /// @dev `keccak256("fallback_manager.handler.address")` — Safe v1.4.1's fallback-handler slot.
    uint256 private constant FALLBACK_HANDLER_STORAGE_SLOT =
        0x6c9a6c4a39284e37ed1cf53d337577d14212a4870fb976a4366c693b939918d5;

    /// @notice Deploys the Safe at its deterministic address, or ADOPTS the one already there.
    /// @dev    Adoption is safe because CREATE2 binds the address to the initializer: anyone who
    ///         landed a Safe here was forced through `SafeProxyFactory.createProxyWithNonce` with
    ///         byte-identical setup data, so the result is what the factory would have produced.
    ///         `requireSafeMatchesConfig` re-verifies that against live state rather than trusting it.
    function deploySafe(
        SafeInfra memory infra,
        address[] memory owners,
        uint256 threshold,
        address[] memory modulesToEnable,
        uint256 nonce
    ) public returns (address safe) {
        safe = predictSafe(infra, owners, threshold, modulesToEnable, nonce);
        if (safe.code.length != 0) {
            requireSafeMatchesConfig(safe, infra.fallbackHandler, owners, threshold, modulesToEnable);
            emit ComponentAdopted(safe, "safe");
            return safe;
        }

        bytes memory initializer = _initializer(infra, owners, threshold, modulesToEnable);
        safe = ISafeProxyFactory(infra.proxyFactory).createProxyWithNonce(infra.singleton, initializer, nonce);
    }

    /// @notice The address `deploySafe` would produce for this configuration.
    function predictSafe(
        SafeInfra memory infra,
        address[] memory owners,
        uint256 threshold,
        address[] memory modulesToEnable,
        uint256 nonce
    ) public view returns (address) {
        bytes memory initializer = _initializer(infra, owners, threshold, modulesToEnable);
        bytes32 salt = keccak256(abi.encodePacked(keccak256(initializer), nonce));
        bytes memory deployment = abi.encodePacked(
            ISafeProxyFactory(infra.proxyFactory).proxyCreationCode(), uint256(uint160(infra.singleton))
        );
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), infra.proxyFactory, salt, keccak256(deployment)))))
        );
    }

    /// @notice Reverts unless the live Safe is exactly what the factory would have deployed.
    /// @dev    Owners, threshold, the EXACT module set, an empty guard slot and the expected fallback
    ///         handler. A squatted Safe whose owners are live config keys could otherwise be mutated
    ///         before adoption and then handed `MANAGER_ROLE`.
    function requireSafeMatchesConfig(
        address safe,
        address expectedFallbackHandler,
        address[] memory owners,
        uint256 threshold,
        address[] memory modulesToEnable
    ) public view {
        if (ISafe(safe).getThreshold() != threshold) revert AdoptedSafeMismatch(safe);
        if (!_matches(ISafe(safe).getOwners(), owners, false)) revert AdoptedSafeMismatch(safe);

        (address[] memory live, address next) =
            ISafe(safe).getModulesPaginated(SENTINEL_MODULES, modulesToEnable.length + 1);
        if (next != SENTINEL_MODULES) revert AdoptedSafeMismatch(safe);
        if (!_matches(live, modulesToEnable, true)) revert AdoptedSafeMismatch(safe);

        if (_safeSlot(safe, GUARD_STORAGE_SLOT) != address(0)) revert AdoptedSafeMismatch(safe);
        if (_safeSlot(safe, FALLBACK_HANDLER_STORAGE_SLOT) != expectedFallbackHandler) {
            revert AdoptedSafeMismatch(safe);
        }
    }

    /// @dev The Safe `setup()` calldata. Byte-identical between prediction and deployment by
    ///      construction, because both call this — which is what makes the predicted address the one
    ///      a third party is forced into if they front-run it.
    function _initializer(
        SafeInfra memory infra,
        address[] memory owners,
        uint256 threshold,
        address[] memory modulesToEnable
    ) private pure returns (bytes memory) {
        bytes memory setupData = abi.encodeCall(ISafeModuleSetup.enableModules, (modulesToEnable));
        return abi.encodeCall(
            ISafe.setup,
            (owners, threshold, infra.moduleSetup, setupData, infra.fallbackHandler, address(0), 0, payable(address(0)))
        );
    }

    /// @dev `reversed` because Safe PREPENDS on `enableModule`, so a live module list comes back in
    ///      the reverse of the order it was enabled in.
    function _matches(address[] memory live, address[] memory expected, bool reversed) private pure returns (bool) {
        if (live.length != expected.length) return false;
        for (uint256 i = 0; i < live.length; i++) {
            if (live[i] != expected[reversed ? expected.length - 1 - i : i]) return false;
        }
        return true;
    }

    /// @dev Reads a raw Safe storage slot. Used for guard and fallback handler, which have no getter.
    function _safeSlot(address safe, uint256 slot) private view returns (address) {
        return address(uint160(uint256(bytes32(ISafe(safe).getStorageAt(slot, 1)))));
    }
}
