// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OivInfraConstants} from "src/OivInfraConstants.sol";

/// @title  OivTestConstants
/// @notice Shared base for the OIV fork/unit test suites. Aliases the canonical Safe/Zodiac infra
///         addresses from the single source (`OivInfraConstants`) exactly once, so each suite can use
///         the short names without re-declaring the block — adding a new infra address touches only
///         `OivInfraConstants` (value) and here (test alias), not every test contract.
/// @dev    Also provides `_requireInfraDeployed`, a fork preflight that turns an opaque deep revert
///         (`TargetHasNoCode` inside `ModuleProxyFactory` when the mastercopy is absent at the forked
///         block) into an immediate, explanatory failure.
abstract contract OivTestConstants is Test {
    // Canonical Safe/Zodiac infra — single source in OivInfraConstants (same values the deploy path
    // bakes into CREATE2 init-code), so the suites always validate what actually ships.
    address constant SAFE_PROXY_FACTORY = OivInfraConstants.SAFE_PROXY_FACTORY;
    address constant SAFE_SINGLETON = OivInfraConstants.SAFE_SINGLETON;
    address constant SAFE_MODULE_SETUP = OivInfraConstants.SAFE_MODULE_SETUP;
    address constant SAFE_FALLBACK_HANDLER = OivInfraConstants.SAFE_FALLBACK_HANDLER;
    address constant MODULE_PROXY_FACTORY = OivInfraConstants.MODULE_PROXY_FACTORY;
    address constant ROLES_MODIFIER_MASTERCOPY = OivInfraConstants.ROLES_MODIFIER_MASTERCOPY;

    /// @notice USDC on mainnet — the shares asset both fork suites use. Shared here so the literal
    ///         lives in one place rather than being re-declared per suite.
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    /// @dev Assert EVERY canonical Safe/Zodiac contract the factory delegates to actually has bytecode
    ///      on the current (forked) chain. Call at the top of a fork-based `setUp` after
    ///      `createSelectFork`. The Roles v2.1.1 mastercopy is the load-bearing one (a fork pinned
    ///      before its mainnet deploy block fails deep inside proxy deployment with `TargetHasNoCode`),
    ///      but all six are checked so a missing Safe module-setup / fallback handler also surfaces as
    ///      an explanatory message here instead of an opaque revert inside the Safe setup delegatecall.
    function _requireInfraDeployed() internal view {
        require(
            ROLES_MODIFIER_MASTERCOPY.code.length > 0,
            "OivTestConstants: Roles v2.1.1 mastercopy has no code at the forked block (pin a later block)"
        );
        require(MODULE_PROXY_FACTORY.code.length > 0, "OivTestConstants: Zodiac ModuleProxyFactory has no code");
        require(SAFE_PROXY_FACTORY.code.length > 0, "OivTestConstants: Safe proxy factory has no code");
        require(SAFE_SINGLETON.code.length > 0, "OivTestConstants: Safe singleton has no code");
        require(SAFE_MODULE_SETUP.code.length > 0, "OivTestConstants: Safe module setup has no code");
        require(SAFE_FALLBACK_HANDLER.code.length > 0, "OivTestConstants: Safe fallback handler has no code");
    }
}
