// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {CcipDeployEverywhere} from "script/CcipDeployEverywhere.s.sol";

/// @dev Exposes the script's internal seeding filter so the test exercises the REAL function rather
///      than a reimplementation of its rules (which would pass even if the script disagreed).
contract SeedScopeHarness is CcipDeployEverywhere {
    function exposed_seedable(string memory json, string memory base) external view returns (bool) {
        return _seedable(json, base);
    }
}

/// @notice Pins which chains `setChainSelectors` will seed into the orchestrator's registry.
/// @dev    `verdict` describes whether a chain COULD host the infra, not whether it DOES. `bob` and
///         `katana` are `READY-AFTER-EMPTY` but have no infra deployed, so before the `excluded`
///         flag existed they were seeded anyway. That is not cosmetic: the no-array
///         `deployEverywhere` fans out to every configured destination, so a selector for a chain
///         with no orchestrator burns a non-refundable CCIP fee on a message whose delivery reverts,
///         and the fund lands everywhere except there.
///
///         It happened for real during the salt-v3 rollout — seeding produced 20 destinations, and
///         the two extras had to be removed with `removeChainSelector` before ownership moved to the
///         Safe (afterwards it would have needed a multisig transaction). This test exists so the
///         next rollout cannot repeat it.
contract SelectorSeedScopeTest is Test {
    using stdJson for string;

    SeedScopeHarness internal harness;
    string internal json;

    function setUp() public {
        harness = new SeedScopeHarness();
        json = vm.readFile("script/ccip-networks.json");
    }

    function test_excludedChainsAreNotSeedable() public view {
        for (uint256 i = 0; i < 256; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".verdict"))) break;
            string memory excludedKey = string.concat(base, ".excluded");
            if (!vm.keyExists(json, excludedKey) || !json.readBool(excludedKey)) continue;

            assertFalse(
                harness.exposed_seedable(json, base),
                string.concat("excluded chain is still seedable: ", json.readString(string.concat(base, ".name")))
            );
        }
    }

    /// @dev The mainnet orchestrator's registry must end up with exactly the destinations that have
    ///      infra deployed: 19 live chains minus mainnet itself (a source, never its own destination).
    function test_seedableCountMatchesDeployedDestinations() public view {
        uint256 count;
        for (uint256 i = 0; i < 256; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".verdict"))) break;
            if (harness.exposed_seedable(json, base)) count++;
        }
        assertEq(count, 18, "seedable destination count drifted from the 18 deployed destinations");
    }

    /// @dev Guards the flag itself: if someone drops `excluded` from bob/katana the count test above
    ///      would fail too, but this names the cause directly.
    function test_bobAndKatanaAreMarkedExcluded() public view {
        assertTrue(_isExcluded("bob"), "bob must stay excluded until its infra is deployed");
        assertTrue(_isExcluded("katana"), "katana must stay excluded until its infra is deployed");
    }

    function _isExcluded(string memory name) internal view returns (bool) {
        for (uint256 i = 0; i < 256; i++) {
            string memory base = string.concat(".networks[", vm.toString(i), "]");
            if (!vm.keyExists(json, string.concat(base, ".verdict"))) break;
            if (keccak256(bytes(json.readString(string.concat(base, ".name")))) != keccak256(bytes(name))) continue;
            string memory k = string.concat(base, ".excluded");
            return vm.keyExists(json, k) && json.readBool(k);
        }
        return false;
    }
}
