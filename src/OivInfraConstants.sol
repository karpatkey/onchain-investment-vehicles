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
///         NOTE: `script/ccip-networks.json` keeps its own copy of these (its `.infra` block) for
///         operator reference. It is a data file, not Solidity, but it is cross-checked against this
///         library by `test/CcipNetworksSync.t.sol::test_infraAddressesMatchLibrary`, so a one-sided
///         edit (bumping a value here without the JSON, or vice versa) fails CI rather than silently
///         drifting. Update both when changing a value.
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

    // ── MultiSend unwrapping ────────────────────────────────────────────────────
    //
    // A Roles Modifier checks permissions per individual call. A `multiSend(bytes)` batch arrives
    // as ONE opaque delegatecall, so without an unwrap adapter registered for the MultiSend target
    // the modifier cannot decompose the batch and rejects it outright — every batched operation
    // fails. The factory therefore registers `MULTISEND_UNWRAPPER` for the `multiSend(bytes)`
    // selector on both MultiSend contracts, on every Roles Modifier it deploys.

    // NOTE: keep the comments below free of dated operational history (which chain got what, when).
    // `foundry.toml` leaves `bytecode_hash` at its solc default, so this file's text is hashed into
    // the metadata of every contract that imports it — editing a comment here moves the CREATE2
    // addresses of KpkOivFactory, KpkSharesDeployer and CcipOivDeployer, forcing a salt bump and a
    // 19-chain re-rollout. Per-chain status and deployment history belong in
    // docs/DEPLOYED_ADDRESSES.md and script/deployed-infra.json, which cost nothing to update.

    /// @notice Gnosis Safe v1.4.1 `MultiSend`.
    address internal constant MULTI_SEND = 0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526;

    /// @notice Gnosis Safe v1.4.1 `MultiSendCallOnly`. Shares the `multiSend(bytes)` selector with
    ///         `MULTI_SEND`, so it needs its own unwrapper registration — the adapter is keyed on
    ///         the (target, selector) pair.
    address internal constant MULTI_SEND_CALLS_ONLY = 0x9641d764fc13c8B624c04430C7356C1C7C8102e2;

    /// @notice Zodiac `MultiSendUnwrapper` — decomposes a `multiSend(bytes)` payload into the
    ///         individual calls the Roles Modifier then permission-checks one by one.
    /// @dev    Deployed via the EIP-2470 SingletonFactory (`0xce0042B868300000d44A59004Da54A005ffdcf9f`)
    ///         with salt 0, so it lands at this address on any chain.
    ///
    ///         GOTCHA: the SingletonFactory swallows a failed inner CREATE2 (returns `address(0)`
    ///         without reverting), so `eth_estimateGas` happily returns a limit at which the
    ///         code-deposit step runs out of gas and the outer tx still "succeeds". Send the deploy
    ///         with an explicit gas limit (~1.5M), then assert EXTCODEHASH — never trust the receipt.
    address internal constant MULTISEND_UNWRAPPER = 0xB4Cd4bb764C089f20DA18700CE8bc5e49F369efD;

    /// @notice `bytes4(keccak256("multiSend(bytes)"))` — the selector both MultiSend contracts expose
    ///         and the one the unwrap adapter is registered against.
    bytes4 internal constant MULTI_SEND_SELECTOR = 0x8d80ff0a;
}
