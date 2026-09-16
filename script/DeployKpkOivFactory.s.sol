// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {OivChainDeploy} from "./base/OivChainDeploy.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";

/// @title  DeployKpkOivFactory
/// @notice **Verifies** that a chain's factory wiring is correct and complete. It does not onboard a
///         chain and it sends no transactions; the name is kept only because
///         `docs/DEPLOYED_ADDRESSES.md` records historical runs under it.
///
/// @dev    It cannot onboard, and three attempts to guard it as though it could each failed for the
///         same underlying reason: only `OivChainDeploy._runChain` wires `timelockDeployer`, and it
///         needs a chain id and CCIP router this entry point does not take.
///
///         It used to try anyway. Until this revision the body still ran `vm.startBroadcast()`,
///         `_ensureEmpty()`, `_ensureMultiSendUnwrapper()`, two CREATE2 deployments,
///         `setKpkSharesMastercopy` and `transferOwnership` — while the header above already
///         described it as a verifier invoked without `--broadcast`. Run as documented, those
///         executed in simulation only, so the script printed `[OK] KpkOivFactory deployed at …`
///         and `[OK] factory.kpkSharesMastercopy set` for state that never reached the chain. A
///         verifier reporting repairs it did not make is the worst possible output for a script
///         whose entire job is telling you whether a chain is what the rollout believes it is.
///
///         The repair path was also already dead in practice: every wired chain has handed the
///         factory to its Safe, so the `onlyOwner` setters are out of reach of any EOA this script
///         could run as, and `transferOwnership` no longer has an owner to transfer from. What is
///         removed here is therefore simulated capability, not real capability.
///
///         To ONBOARD a chain use `script/chains/Deploy_<Chain>.s.sol`.
///
/// Usage (per chain) — read-only, no `--broadcast`, no `--sender`, no key:
///   forge script script/DeployKpkOivFactory.s.sol:DeployKpkOivFactory \
///     --rpc-url <chain> --sig "run(address,address)" <eoaOwner> <finalOwner>
///
///   `eoaOwner` is still required because the factory's CREATE2 salt binds it, so its address cannot
///   be derived without it. It is used for prediction only; this script never acts as it.
contract DeployKpkOivFactory is OivChainDeploy {
    function run(address eoaOwner, address finalOwner) external view {
        require(eoaOwner != address(0), "eoaOwner is zero");
        require(finalOwner != address(0), "finalOwner is zero");

        address predictedFactory = _create2Address(SALT_FACTORY, _factoryInitCode(eoaOwner));
        address predictedMastercopy = _create2Address(SALT_SHARES_MASTERCOPY, _sharesMastercopyInitCode());

        console.log("==========================================");
        console.log("  VERIFY ONLY - this script sends nothing");
        console.log("==========================================");
        console.log("Expected KpkOivFactory:        ", predictedFactory);
        console.log("Expected KpkShares mastercopy: ", predictedMastercopy);
        console.log("Expected final owner:          ", finalOwner);
        console.log("------------------------------------------");

        // Every check below is an assertion about live chain state. None of them can be satisfied by
        // this script, which is the point: a failure here means the chain needs
        // `script/chains/Deploy_<Chain>.s.sol`, not a re-run of this one.
        require(predictedFactory.code.length > 0, "factory is not deployed on this chain");
        console.log("[OK]   factory present");

        KpkOivFactory factory = KpkOivFactory(predictedFactory);

        require(EMPTY.code.length > 0, "Empty is not deployed on this chain");
        require(keccak256(EMPTY.code) == keccak256(EMPTY_RUNTIME), "Empty: unexpected bytecode at canonical address");
        console.log("[OK]   Empty canonical at      ", EMPTY);

        require(MULTI_SEND.codehash == MULTI_SEND_CODEHASH, "MultiSend missing/non-canonical on this chain");
        require(
            MULTI_SEND_CALLS_ONLY.codehash == MULTI_SEND_CALLS_ONLY_CODEHASH,
            "MultiSendCallOnly missing/non-canonical on this chain"
        );
        require(
            MULTISEND_UNWRAPPER.codehash == MULTISEND_UNWRAPPER_CODEHASH,
            "MultiSendUnwrapper missing/non-canonical - batched fund transactions would be rejected"
        );
        console.log("[OK]   MultiSend + unwrapper canonical");

        // The wiring that this script historically failed to perform, and the reason it must never
        // claim a chain is ready: without it every timelocked fund reverts `TimelockDeployerNotSet`,
        // and in a CCIP fan-out the destination reverts with the source-chain fee already spent.
        require(
            factory.timelockDeployer() == _predictTimelockDeployer(),
            "timelockDeployer is unset or not the canonical one for this generation"
        );
        console.log("[OK]   timelockDeployer        ", factory.timelockDeployer());

        require(factory.kpkSharesMastercopy() == predictedMastercopy, "kpkSharesMastercopy mismatch");
        console.log("[OK]   kpkSharesMastercopy     ", factory.kpkSharesMastercopy());

        require(factory.owner() == finalOwner, "factory owner is not the expected final owner");
        console.log("[OK]   owner                   ", factory.owner());

        console.log("==========================================");
        console.log("  Chain verified.");
        console.log("==========================================");
    }
}
