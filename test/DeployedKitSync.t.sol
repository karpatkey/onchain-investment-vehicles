// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {OivChainDeploy} from "script/base/OivChainDeploy.sol";

/// @title  DeployedKitSync
/// @notice The guard the drift guards cannot be. `FactoryAddressSync` compares a pinned address to
///         the PREDICTION, and both are computed from the same source — so when a comment-only edit
///         moved `KpkTimelockDeployer`'s predicted address off the contract that is actually live on
///         mainnet, every guard stayed green and `docs/DEPLOYED_ADDRESSES.md` went on calling the
///         whole salt-v4 set "NOT DEPLOYED — predictions only". Nothing in the repo compared either
///         number to the chain.
///
/// @dev    This asserts against REALITY: the timelock kit is deployed, so whatever this branch
///         predicts for it must have code. Editing `src/KpkTimelockDeployer.sol`, anything in its
///         import graph (`src/interfaces/IKpkTimelockDeployer.sol`), or any global compiler input that
///         reaches it (`evm_version`, `optimizer_runs`, `bytecode_hash`) moves that prediction to an
///         empty address and fails here — which is the point. A failure is not necessarily a bug: it
///         is the question "do you mean to fork the deployed timelock kit?" asked at the only moment
///         it is cheap to answer.
///
///         Fork test by necessity — it needs chain state, which is exactly what the other guards lack.
///         Run with `--fork-url $MAINNET_URL`; skipped when no RPC is configured.
contract DeployedKitSyncTest is Test, OivChainDeploy {
    /// @dev Verified live on mainnet 2026-09-23: `timelockMastercopy() == 0x9760280f…`,
    ///      `MAX_ROLE_MEMBERS() == 10`, `MIN_DELAY_FLOOR() == 43200`.
    address internal constant LIVE_TIMELOCK_DEPLOYER = 0xdd23Ba8B2c4D3D916605361e29600121DeFC2d9f;
    address internal constant LIVE_TIMELOCK_MASTERCOPY = 0x9760280fED9e760668186334f88b6d763A7d976E;

    function setUp() public {
        try vm.envString("MAINNET_URL") returns (string memory url) {
            vm.createSelectFork(url);
        } catch {
            vm.skip(true);
        }
    }

    /// @notice What this branch predicts for the timelock deployer must be the contract that is live,
    ///         because that kit is already deployed and its clones govern live funds.
    function test_predictedTimelockDeployerIsTheLiveOne() public view {
        assertEq(
            _predictTimelockDeployer(),
            LIVE_TIMELOCK_DEPLOYER,
            "this branch would deploy a DIFFERENT KpkTimelockDeployer than the live one - forking the kit"
        );
        assertGt(LIVE_TIMELOCK_DEPLOYER.code.length, 0, "the live deployer must actually have code");
    }

    /// @notice And its mastercopy, which the deployer embeds as an immutable, so a change to either
    ///         moves both.
    function test_predictedTimelockMastercopyIsTheLiveOne() public view {
        assertEq(
            _create2Address(SALT_TIMELOCK_MASTERCOPY, _timelockMastercopyInitCode()),
            LIVE_TIMELOCK_MASTERCOPY,
            "the predicted TimelockControllerUpgradeable mastercopy is not the live one"
        );
        assertGt(LIVE_TIMELOCK_MASTERCOPY.code.length, 0, "the live mastercopy must actually have code");
    }
}
