// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  OivInfraConstants
/// @notice Single source of truth for the canonical, same-on-every-chain infra addresses that the
///         OIV deploy path bakes into CREATE2 init-code and that the test suites fork against.
/// @dev    Both `script/base/OivChainDeploy.sol` (the deploy path) and the test suites reference
///         these constants so a value can never drift between what actually deploys and what the
///         tests validate. Before this library the Roles Modifier mastercopy in particular was a
///         hand-maintained literal in five places, so a single version bump had to touch each by
///         hand and a miss would silently validate against a stale mastercopy.
///
///         NOTE: `script/ccip-networks.json` keeps its own copy of some of these (notably
///         `rolesModifierMastercopy`) for operator reference. It is a data file, not Solidity, and
///         is NOT cross-checked against this library by any test — `test/CcipNetworksSync.t.sol`
///         validates only the registry's per-chain router/LINK/selector/verdict, not these infra
///         addresses. So when bumping a value here, update `ccip-networks.json` by hand in lockstep.
library OivInfraConstants {
    // ── Safe v1.4.1 ─────────────────────────────────────────────────────────────
    address internal constant SAFE_PROXY_FACTORY = 0xa6B71E26C5e0845f74c812102Ca7114b6a896AB2;
    address internal constant SAFE_SINGLETON = 0x41675C099F32341bf84BFc5382aF534df5C7461a;
    address internal constant SAFE_MODULE_SETUP = 0x2dd68b007B46fBe91B9A7c3EDa5A7a1063cB5b47;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    // ── Zodiac ──────────────────────────────────────────────────────────────────
    address internal constant MODULE_PROXY_FACTORY = 0x000000000000aDdB49795b0f9bA5BC298cDda236;

    /// @notice PATCHED Roles Modifier v2.1.1 mastercopy. All Roles Modifier proxies delegate to this.
    /// @dev    v2.1.0 (`0x9646fDAD06d3e24444381f44362a3B0eB343D337`) had the June-2026 ERC-1271
    ///         authorization bypass (triggerable when a Safe using the CompatibilityFallbackHandler
    ///         is a role member — exactly this architecture), so the whole stack must use v2.1.1.
    address internal constant ROLES_MODIFIER_MASTERCOPY = 0xF2964CE6161ce0e75964Fe7927cE114cb0B283D5;
}
