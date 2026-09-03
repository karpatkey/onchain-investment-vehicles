// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../../src/KpkOivFactory.sol";
import {KpkShares} from "../../src/kpkShares.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {KpkTimelockDeployer} from "../../src/KpkTimelockDeployer.sol";
import {CcipOivDeployer} from "../../src/CcipOivDeployer.sol";
import {OivInfraConstants} from "../../src/OivInfraConstants.sol";

/// @title  OivChainDeploy
/// @notice Single source of truth for the OIV deploy primitives. Holds the canonical infra
///         constants, the deterministic salts, the init-code builders, the CREATE2 address helper,
///         and the `Empty` onboarding step. `DeployKpkOivFactory`, `DeployCcipOivDeployer`,
///         `DeployEmpty`, and every per-chain script in `script/chains/` inherit this so the
///         address-critical code exists in EXACTLY ONE place — the cross-chain same-address
///         invariant (which `CcipOivDeployer.ccipReceive` trusts) cannot drift between the
///         standalone and per-chain paths.
///
/// @dev    Canonical Safe/Zodiac infra values (incl. the patched Roles v2.1.1 mastercopy) come from
///         `OivInfraConstants` — see there for the single-source rationale (why v2.1.0 is forbidden).
abstract contract OivChainDeploy is Script {
    // ── Canonical infra (same address on every chain) ──────────────────────────
    address internal constant CANONICAL_CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    // Canonical Safe/Zodiac infra — sourced from the shared OivInfraConstants so the deploy path and
    // the test suites can never validate a different value than what actually deploys.
    address internal constant SAFE_PROXY_FACTORY = OivInfraConstants.SAFE_PROXY_FACTORY;
    address internal constant SAFE_SINGLETON = OivInfraConstants.SAFE_SINGLETON;
    address internal constant SAFE_MODULE_SETUP = OivInfraConstants.SAFE_MODULE_SETUP;
    address internal constant SAFE_FALLBACK_HANDLER = OivInfraConstants.SAFE_FALLBACK_HANDLER;
    address internal constant MODULE_PROXY_FACTORY = OivInfraConstants.MODULE_PROXY_FACTORY;
    address internal constant ROLES_MODIFIER_MASTERCOPY = OivInfraConstants.ROLES_MODIFIER_MASTERCOPY;

    /// @notice Old, pre-v2.1.1 factory (vulnerable Roles v2.1.0 build). Guarded against so it is
    ///         never wired into a freshly-deployed orchestrator.
    address internal constant LEGACY_FACTORY = 0x0d94255fdE65D302616b02A2F070CdB21190d420;

    // ── Empty onboarding ───────────────────────────────────────────────────────
    address internal constant EMPTY = 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652;
    address internal constant EMPTY_HELPER_FACTORY = 0x7cbB62EaA69F79e6873cD1ecB2392971036cFAa4;
    /// @dev Exact creation calldata from the canonical Empty deployment (mainnet tx 0xc424…c8a2):
    ///      selector 0x4847be6f + fixed salt + the Empty creation bytecode. Caller-independent
    ///      CREATE2 (verified on a Polygon fork). THE ONLY copy of this calldata in the repo.
    bytes internal constant EMPTY_CREATE_CALLDATA =
        hex"4847be6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060307831313933333333333331393235323536383234373334353633343131000000000000000000000000000000000000000000000000000000000000000000586080604052348015600e575f5ffd5b50603e80601a5f395ff3fe60806040525f5ffdfea2646970667358221220dddfa414d3e674246761d7c4ce7ba241adbe729cb02d75a50b9cac1086c72cdf64736f6c634300081b00330000000000000000";
    /// @dev The canonical `Empty` runtime — the 62 bytes returned by deploying `EMPTY_CREATE_CALLDATA`
    ///      (the tail of the creation code after the `603e80601a5f395ff3` constructor). Every call
    ///      reverts, which is what makes the Avatar Safe non-executable except via the Roles module.
    ///      We assert any code already at `EMPTY` matches this, so a different contract squatting the
    ///      address (e.g. one implementing ERC-1271) can never be trusted as the Avatar's sole signer.
    bytes internal constant EMPTY_RUNTIME =
        hex"60806040525f5ffdfea2646970667358221220dddfa414d3e674246761d7c4ce7ba241adbe729cb02d75a50b9cac1086c72cdf64736f6c634300081b0033";

    // ── Deterministic salts ────────────────────────────────────────────────────
    // Version 3: the MultiSend unwrap-adapter fix changed the factory's runtime, so its CREATE2
    // address moves regardless of the salt; the bump keeps the version counter honest per the
    // convention in docs/DEPLOYED_ADDRESSES.md ("bump the version uint to redeploy at a fresh
    // address after a bytecode change"). The factory and orchestrator move together: the orchestrator takes the
    // factory address as a constructor arg and CcipOivDeployer takes it as an immutable, so both
    // init codes change with the factory. `Empty` is untouched and keeps its address.
    //
    // ROLLOUT CONSTRAINT — a fund must never straddle two factory versions. `_deployAndWireStack`
    // bakes the factory's own address into the Avatar Safe's `setup()` initializer (it is enabled
    // as a setup-time module), and the Safe address is derived from `keccak(initializer)`. So the
    // same `(caller, salt)` run through a v2 factory on one chain and a v3 factory on another
    // yields DIFFERENT Avatar Safe addresses — silently, with nothing on-chain to detect it. Finish
    // the v3 rollout on every chain before deploying any new fund.
    //
    // Version 2 (factory 0xfff31e99…f965) was the EOA-owned-then-handover rollout; version 1
    // (factory 0xfb76…25f0) handed ownership to the Safe at deploy time, which left owner-only
    // setup (setChainSelectors) stranded behind the multisig.
    bytes32 internal constant SALT_FACTORY = keccak256(abi.encodePacked("KpkOivFactory", uint256(4)));
    bytes32 internal constant SALT_SHARES_MASTERCOPY = keccak256(abi.encodePacked("KpkSharesMastercopy", uint256(4)));
    bytes32 internal constant SALT_TIMELOCK_MASTERCOPY =
        keccak256(abi.encodePacked("TimelockControllerMastercopy", uint256(4)));
    bytes32 internal constant SALT_CCIP = keccak256(abi.encodePacked("CcipOivDeployer", uint256(4)));
    bytes32 internal constant SALT_TIMELOCK = keccak256(abi.encodePacked("KpkTimelockDeployer", uint256(4)));

    // ── MultiSend unwrap adapter ───────────────────────────────────────────────
    //
    // The factory hard-reverts `MultiSendUnwrapperMissing` / `MultiSendMissing` unless all three of
    // these are canonical, because registering an unwrap adapter turns its target into an
    // unconditional DELEGATECALL sink for every role. Without a preflight a freshly onboarded chain
    // would pass every readiness gate, deploy the infra, and only fail when a fund is deployed —
    // or worse, mid CCIP fan-out, leaving the fund at its deterministic addresses on every chain
    // but one and breaking the same-address invariant the whole design exists for.

    /// @dev EIP-2470 SingletonFactory. Deploys `MULTISEND_UNWRAPPER` at its canonical address from
    ///      caller-independent CREATE2 (salt 0), so it can be onboarded permissionlessly.
    address internal constant SINGLETON_FACTORY = 0xce0042B868300000d44A59004Da54A005ffdcf9f;

    address internal constant MULTI_SEND = OivInfraConstants.MULTI_SEND;
    address internal constant MULTI_SEND_CALLS_ONLY = OivInfraConstants.MULTI_SEND_CALLS_ONLY;
    address internal constant MULTISEND_UNWRAPPER = OivInfraConstants.MULTISEND_UNWRAPPER;

    bytes32 internal constant MULTI_SEND_CODEHASH = 0x0e4f7fc66550a322d1e7688e181b75e217e662a4f3f4d6a29b22bc61217c4b77;
    bytes32 internal constant MULTI_SEND_CALLS_ONLY_CODEHASH =
        0xecd5bd14a08c5d2122379900b2f272bdf107a7e92423c10dd5fe3254386c9939;
    bytes32 internal constant MULTISEND_UNWRAPPER_CODEHASH =
        0x1f6e088be5e6ef9d0fbe0547d3fa9a9e40d823433fd8a4449215b5663209a1eb;

    /// @dev Creation code of the Zodiac `MultiSendUnwrapper`, taken verbatim from the mainnet deploy
    ///      transaction. With salt 0 through `SINGLETON_FACTORY` it reproduces `MULTISEND_UNWRAPPER`
    ///      on any chain.
    bytes internal constant MULTISEND_UNWRAPPER_INIT_CODE =
        hex"608060405234801561000f575f80fd5b506108308061001d5f395ff3fe608060405234801561000f575f80fd5b5060043610610029575f3560e01c8063c7a7b6351461002d575b5f80fd5b61004061003b36600461052c565b610056565b60405161004d91906105e3565b60405180910390f35b606084156100775760405163ad6e405560e01b815260040160405180910390fd5b600182600181111561008b5761008b6105cf565b146100a95760405163ad6e405560e01b815260040160405180910390fd5b6100b384846100d6565b5f6100be85856101a1565b90506100cb8585836102b8565b979650505050505050565b6346c07f8560e11b6100e88284610677565b6001600160e01b0319161461011057604051631a751fb760e11b815260040160405180910390fd5b602061011f82600481866106a5565b610128916106cc565b1461014657604051631a751fb760e11b815260040160405180910390fd5b5f61015482602481866106a5565b61015d916106cc565b90508161017361016e8360406106fd565b6104e5565b61017e9060046106fd565b1461019c57604051631a751fb760e11b815260040160405180910390fd5b505050565b5f6044816101b284602481886106a5565b6101bb916106cc565b6101c69060446106fd565b90505b80821015610291575f6101de858481896106a5565b6101e791610710565b60f81c9050600181111561020d57604051629ec3f960e31b815260040160405180910390fd5b5f868661021b8660356106fd565b6102269282906106a5565b61022f916106cc565b9050828161023e8660556106fd565b61024891906106fd565b111561026657604051629ec3f960e31b815260040160405180910390fd5b6102718160556106fd565b61027b90856106fd565b9350846102878161073e565b95505050506101c9565b825f036102b057604051629ec3f960e31b815260040160405180910390fd5b505092915050565b60608167ffffffffffffffff8111156102d3576102d3610756565b60405190808252806020026020018201604052801561033b57816020015b6103286040805160a08101909152805f81526020015f6001600160a01b031681526020015f81526020015f81526020015f81525090565b8152602001906001900390816102f15790505b50905060445f5b838110156104dc57610356858381896106a5565b61035f91610710565b60f81c6001811115610373576103736105cf565b8382815181106103855761038561076a565b60200260200101515f019060018111156103a1576103a16105cf565b908160018111156103b4576103b46105cf565b9052506103c26001836106fd565b91506103d0858381896106a5565b6103d99161077e565b60601c8382815181106103ee576103ee61076a565b6020908102919091018101516001600160a01b039092169101526104136014836106fd565b9150610421858381896106a5565b61042a916106cc565b5f1c83828151811061043e5761043e61076a565b6020026020010151604001818152505060208261045b91906106fd565b91505f61046a8684818a6106a5565b610473916106cc565b90506104806020846106fd565b9250828483815181106104955761049561076a565b60200260200101516060018181525050808483815181106104b8576104b861076a565b6020908102919091010151608001526104d181846106fd565b925050600101610342565b50509392505050565b5f602060016104f484836106fd565b6104fe91906107b1565b61050891906107c4565b6105139060206107e3565b92915050565b803560028110610527575f80fd5b919050565b5f805f805f60808688031215610540575f80fd5b85356001600160a01b0381168114610556575f80fd5b945060208601359350604086013567ffffffffffffffff80821115610579575f80fd5b818801915088601f83011261058c575f80fd5b81358181111561059a575f80fd5b8960208285010111156105ab575f80fd5b6020830195508094505050506105c360608701610519565b90509295509295909350565b634e487b7160e01b5f52602160045260245ffd5b602080825282518282018190525f91906040908185019086840185805b8381101561066957825180516002811061062857634e487b7160e01b84526021600452602484fd5b8652808801516001600160a01b0316888701528681015187870152606080820151908701526080908101519086015260a09094019391860191600101610600565b509298975050505050505050565b6001600160e01b031981358181169160048510156102b05760049490940360031b84901b1690921692915050565b5f80858511156106b3575f80fd5b838611156106bf575f80fd5b5050820193919092039150565b80356020831015610513575f19602084900360031b1b1692915050565b634e487b7160e01b5f52601160045260245ffd5b80820180821115610513576105136106e9565b6001600160f81b031981358181169160018510156102b05760019490940360031b84901b1690921692915050565b5f6001820161074f5761074f6106e9565b5060010190565b634e487b7160e01b5f52604160045260245ffd5b634e487b7160e01b5f52603260045260245ffd5b6bffffffffffffffffffffffff1981358181169160148510156102b05760149490940360031b84901b1690921692915050565b81810381811115610513576105136106e9565b5f826107de57634e487b7160e01b5f52601260045260245ffd5b500490565b8082028115828204841417610513576105136106e956fea264697066735822122039836a916c6e77cf306bccef03cf05dd5cb638d5ac3fd8bde58b82582f3be8bb64736f6c63430008150033";

    /// @notice CCIP selector of Ethereum mainnet — the trusted source on every chain.
    uint64 internal constant MAINNET_SELECTOR = 5009297550715157269;

    // ── Init-code builders (the address-critical code; reused everywhere) ─────────

    function _factoryInitCode(address eoaOwner) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(KpkOivFactory).creationCode,
            abi.encode(
                eoaOwner,
                SAFE_PROXY_FACTORY,
                SAFE_SINGLETON,
                SAFE_MODULE_SETUP,
                SAFE_FALLBACK_HANDLER,
                MODULE_PROXY_FACTORY,
                ROLES_MODIFIER_MASTERCOPY,
                address(0), // placeholder — wired post-deploy via setKpkSharesMastercopy
                address(0) // placeholder — wired post-deploy via setTimelockDeployer
            )
        );
    }

    /// @dev `KpkTimelockDeployer` takes no constructor arguments, so it lands at the same address on
    ///      every chain without the factory's chicken-and-egg dance.
    function _timelockDeployerInitCode() internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(KpkTimelockDeployer).creationCode,
            abi.encode(_create2Address(SALT_TIMELOCK_MASTERCOPY, _timelockMastercopyInitCode()))
        );
    }

    /// @dev Both mastercopies take no constructor arguments, so each lands at one address on every
    ///      chain and the contracts that reference them stay chain-independent.
    function _sharesMastercopyInitCode() internal pure returns (bytes memory) {
        return type(KpkShares).creationCode;
    }

    function _timelockMastercopyInitCode() internal pure returns (bytes memory) {
        return type(TimelockControllerUpgradeable).creationCode;
    }

    function _orchestratorInitCode(address eoaOwner, address factory) internal pure returns (bytes memory) {
        return abi.encodePacked(type(CcipOivDeployer).creationCode, abi.encode(eoaOwner, factory));
    }

    function _predictFactory(address eoaOwner) internal pure returns (address) {
        return _create2Address(SALT_FACTORY, _factoryInitCode(eoaOwner));
    }

    /// @dev `KpkTimelockDeployer`'s only constructor argument is the timelock mastercopy, which is
    ///      itself at one address on every chain, so its address is likewise chain-independent and
    ///      independent of the deployer EOA.
    function _predictTimelockDeployer() internal pure returns (address) {
        return _create2Address(SALT_TIMELOCK, _timelockDeployerInitCode());
    }

    /// @dev keccak256(0xff || deployer || salt || keccak256(initCode))[12:].
    function _create2Address(bytes32 salt, bytes memory initCode) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xff), CANONICAL_CREATE2_DEPLOYER, salt, keccak256(initCode)))
                )
            )
        );
    }

    // ── Empty preflight (shared by DeployEmpty + _runChain) ──────────────────────

    /// @dev Ensures `Empty` is at its canonical address. Idempotent. MUST be called inside an active
    ///      `vm.startBroadcast()`. Reverts if it cannot land `Empty` at the canonical address.
    function _ensureEmpty() internal {
        if (EMPTY.code.length > 0) {
            // Defense-in-depth: a non-empty address is NOT enough — verify it is the canonical
            // `Empty` runtime, never an arbitrary contract squatting the address.
            require(
                keccak256(EMPTY.code) == keccak256(EMPTY_RUNTIME), "Empty: unexpected bytecode at canonical address"
            );
            console.log("[SKIP] Empty already at:             ", EMPTY);
            return;
        }
        require(EMPTY_HELPER_FACTORY.code.length > 0, "Empty helper factory missing on this chain");
        (bool ok,) = EMPTY_HELPER_FACTORY.call(EMPTY_CREATE_CALLDATA);
        require(ok, "Empty deploy via helper factory failed");
        require(keccak256(EMPTY.code) == keccak256(EMPTY_RUNTIME), "Empty: unexpected bytecode after deploy");
        console.log("[OK]   Empty deployed at:            ", EMPTY);
    }

    /// @dev Onboards the MultiSend unwrap adapter, and asserts both MultiSend contracts are the
    ///      canonical Safe v1.4.1 builds. The factory reverts on all three at fund-deploy time; doing
    ///      it here means a chain fails during infra deploy — loudly, on the operator's terminal —
    ///      rather than when a fund is deployed, or halfway through a paid CCIP fan-out.
    ///
    ///      The two MultiSends cannot be onboarded from here (they are Safe's own deterministic
    ///      deployments); a chain without them is not Safe-ready and must not be wired at all.
    function _ensureMultiSendUnwrapper() internal {
        require(MULTI_SEND.codehash == MULTI_SEND_CODEHASH, "MultiSend missing/non-canonical on this chain");
        require(
            MULTI_SEND_CALLS_ONLY.codehash == MULTI_SEND_CALLS_ONLY_CODEHASH,
            "MultiSendCallOnly missing/non-canonical on this chain"
        );

        if (MULTISEND_UNWRAPPER.codehash == MULTISEND_UNWRAPPER_CODEHASH) {
            console.log("[SKIP] MultiSendUnwrapper already at:", MULTISEND_UNWRAPPER);
            return;
        }
        require(MULTISEND_UNWRAPPER.code.length == 0, "MultiSendUnwrapper: unexpected bytecode at canonical address");
        require(SINGLETON_FACTORY.code.length > 0, "EIP-2470 SingletonFactory missing on this chain");

        // GOTCHA: SingletonFactory.deploy swallows a failed inner CREATE2 — it returns address(0)
        // instead of reverting, so `ok` is true and the receipt reads status 1 even when the code
        // deposit ran out of gas. (That is exactly how the first Linea/Scroll attempt burned gas and
        // deployed nothing.) The post-condition below is the only trustworthy signal, so assert the
        // codehash rather than the call's success.
        (bool ok,) = SINGLETON_FACTORY.call(
            abi.encodeWithSignature("deploy(bytes,bytes32)", MULTISEND_UNWRAPPER_INIT_CODE, bytes32(0))
        );
        require(ok, "MultiSendUnwrapper deploy call reverted");
        require(
            MULTISEND_UNWRAPPER.codehash == MULTISEND_UNWRAPPER_CODEHASH,
            "MultiSendUnwrapper: not deployed (inner CREATE2 likely out of gas - raise the tx gas limit)"
        );
        console.log("[OK]   MultiSendUnwrapper deployed at:", MULTISEND_UNWRAPPER);
    }

    // ── Full per-chain deploy ────────────────────────────────────────────────────

    /// @notice Empty preflight → factory + deployer → orchestrator (+configure), in one broadcast.
    /// @param expectedChainId The chain this script's hardcoded router/LINK belong to. Guarded against
    ///                   `block.chainid` so a wrong `--rpc-url` cannot configure the orchestrator with
    ///                   one chain's CCIP params on another (the post-flight checks compare against the
    ///                   same hardcoded constants, so without this guard a wrong chain passes silently).
    /// @param eoaOwner   Initial owner; MUST equal the broadcasting sender (enforced below) since it
    ///                   is baked into the CREATE2 init-code and calls the onlyOwner setters.
    /// @param finalOwner Owner after handoff (pass == eoaOwner to keep control, e.g. for testing).
    /// @param ccipRouter CCIP Router on THIS chain.
    /// @param linkToken  CCIP LINK fee token on THIS chain.
    function _runChain(
        uint256 expectedChainId,
        address eoaOwner,
        address finalOwner,
        address ccipRouter,
        address linkToken
    ) internal {
        require(block.chainid == expectedChainId, "wrong chain: block.chainid != this script's chain (check --rpc-url)");
        require(eoaOwner != address(0) && finalOwner != address(0), "owner is zero");
        require(ccipRouter != address(0) && linkToken != address(0), "ccip arg is zero");
        // The broadcasting key signs the onlyOwner setters; it must be `eoaOwner` (which is also
        // baked into the factory/orchestrator init-code), or those calls would revert mid-broadcast.
        require(msg.sender == eoaOwner, "broadcasting sender must equal eoaOwner");

        bytes memory factoryInitCode = _factoryInitCode(eoaOwner);
        bytes memory sharesMastercopyInitCode = _sharesMastercopyInitCode();
        bytes memory timelockMastercopyInitCode = _timelockMastercopyInitCode();
        address factory = _create2Address(SALT_FACTORY, factoryInitCode);
        address sharesMastercopy = _create2Address(SALT_SHARES_MASTERCOPY, sharesMastercopyInitCode);
        address timelockMastercopy = _create2Address(SALT_TIMELOCK_MASTERCOPY, timelockMastercopyInitCode);
        bytes memory ccipInitCode = _orchestratorInitCode(eoaOwner, factory);
        address orchestrator = _create2Address(SALT_CCIP, ccipInitCode);
        address timelockDeployer = _create2Address(SALT_TIMELOCK, _timelockDeployerInitCode());

        console.log("==========================================");
        console.log("Chain id:                ", block.chainid);
        console.log("Predicted KpkOivFactory: ", factory);
        console.log("Predicted KpkShares mastercopy:", sharesMastercopy);
        console.log("Predicted Timelock mastercopy:", timelockMastercopy);
        console.log("Predicted CcipOivDeployer:", orchestrator);
        console.log("Predicted KpkTimelockDeployer:", timelockDeployer);
        console.log("CCIP router:             ", ccipRouter);
        console.log("LINK token:              ", linkToken);
        console.log("==========================================");

        vm.startBroadcast();

        // ── 1. Empty + MultiSend-unwrapping preflight ──
        _ensureEmpty();
        _ensureMultiSendUnwrapper();

        // ── 2. Factory + deployer ──
        if (factory.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_FACTORY, factoryInitCode));
            require(ok, "factory CREATE2 deploy failed");
            console.log("[OK]   KpkOivFactory deployed at:    ", factory);
        } else {
            console.log("[SKIP] KpkOivFactory already at:     ", factory);
        }
        if (sharesMastercopy.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_SHARES_MASTERCOPY, sharesMastercopyInitCode));
            require(ok, "shares mastercopy CREATE2 deploy failed");
            console.log("[OK]   KpkShares mastercopy deployed at:", sharesMastercopy);
        } else {
            console.log("[SKIP] KpkShares mastercopy already at: ", sharesMastercopy);
        }
        // Must exist BEFORE the timelock deployer: its constructor rejects a codeless mastercopy.
        if (timelockMastercopy.code.length == 0) {
            (bool ok,) =
                CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_TIMELOCK_MASTERCOPY, timelockMastercopyInitCode));
            require(ok, "timelock mastercopy CREATE2 deploy failed");
            console.log("[OK]   Timelock mastercopy deployed at:", timelockMastercopy);
        } else {
            console.log("[SKIP] Timelock mastercopy already at: ", timelockMastercopy);
        }
        if (timelockDeployer.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_TIMELOCK, _timelockDeployerInitCode()));
            require(ok, "timelock deployer CREATE2 deploy failed");
            console.log("[OK]   KpkTimelockDeployer deployed at:", timelockDeployer);
        } else {
            console.log("[SKIP] KpkTimelockDeployer already at:", timelockDeployer);
        }

        KpkOivFactory f = KpkOivFactory(factory);
        if (f.kpkSharesMastercopy() == address(0)) {
            f.setKpkSharesMastercopy(sharesMastercopy);
            console.log("[OK]   factory.kpkSharesMastercopy set");
        } else {
            require(f.kpkSharesMastercopy() == sharesMastercopy, "factory shares mastercopy mismatch");
        }
        if (f.timelockDeployer() == address(0)) {
            f.setTimelockDeployer(timelockDeployer);
            console.log("[OK]   factory.timelockDeployer set");
        } else {
            require(f.timelockDeployer() == timelockDeployer, "factory timelock deployer mismatch");
        }
        if (f.owner() == eoaOwner && eoaOwner != finalOwner) {
            f.transferOwnership(finalOwner);
        }

        // ── 3. Orchestrator + configure ──
        if (orchestrator.code.length == 0) {
            (bool ok,) = CANONICAL_CREATE2_DEPLOYER.call(abi.encodePacked(SALT_CCIP, ccipInitCode));
            require(ok, "orchestrator CREATE2 deploy failed");
            console.log("[OK]   CcipOivDeployer deployed at:  ", orchestrator);
        } else {
            console.log("[SKIP] CcipOivDeployer already at:   ", orchestrator);
        }
        CcipOivDeployer orch = CcipOivDeployer(payable(orchestrator));
        if (orch.owner() == eoaOwner) {
            if (orch.router() != ccipRouter || orch.linkToken() != linkToken) {
                orch.configure(ccipRouter, linkToken);
                console.log("[OK]   orchestrator configured");
            }
            if (eoaOwner != finalOwner) orch.transferOwnership(finalOwner);
        }

        vm.stopBroadcast();

        // ── Post-flight: assert the END STATE, regardless of which branches ran ──
        require(KpkOivFactory(factory).kpkSharesMastercopy() == sharesMastercopy, "post: shares mastercopy not wired");
        require(KpkOivFactory(factory).timelockDeployer() == timelockDeployer, "post: timelock deployer not wired");
        require(KpkOivFactory(factory).owner() == finalOwner, "post: factory owner != finalOwner");
        require(address(orch.factory()) == factory, "post: orch factory mismatch");
        require(orch.owner() == finalOwner, "post: orchestrator owner != finalOwner");

        bool configured = orch.router() == ccipRouter && orch.linkToken() == linkToken;
        if (!configured) {
            // The orchestrator is owned by finalOwner but not (correctly) configured — only reachable
            // on a re-run of a chain whose first deploy handed off ownership before `configure()` landed
            // (configure is gated on `orch.owner() == eoaOwner`, so this script can no longer do it).
            // Surface the exact remaining action instead of a bare revert, and do NOT print "Chain
            // ready" — so this is an [ACTION REQUIRED], not a false-positive success.
            console.log("[ACTION REQUIRED] orchestrator deployed but NOT configured; finalOwner must call");
            console.log("  configure(router, link):");
            console.log("  router:  ", ccipRouter);
            console.log("  link:    ", linkToken);
            return;
        }
        console.log("[OK] Chain ready. Factory + orchestrator deployed, configured & owned by finalOwner.");
    }
}
