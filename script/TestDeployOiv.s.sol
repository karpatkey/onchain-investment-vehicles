// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {KpkOivFactory} from "../src/KpkOivFactory.sol";
import {KpkShares} from "../src/kpkShares.sol";

/// @title  TestDeployOiv
/// @notice Smoke-test invocation of `KpkOivFactory.deployOiv` on the live Mainnet factory
///         (`0x0d94255fdE65D302616b02A2F070CdB21190d420`) with a minimal disposable config:
///         deployer EOA as the sole Manager Safe signer (threshold 1) and as the OIV admin.
///
///         WITHOUT `--broadcast`: prints the 7 predicted addresses + simulates the deploy in
///         memory. Free. Use this to sanity-check the full call path before paying gas.
///         WITH `--broadcast`: predicts first (still printed), then broadcasts the deployOiv
///         transaction. Costs ~$30-60 in gas at typical Mainnet prices.
///
///         Usage:
///           # Predict only (free)
///           forge script script/TestDeployOiv.s.sol:TestDeployOiv \
///             --rpc-url mainnet \
///             --sender 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72
///
///           # Broadcast (real test deploy on Mainnet)
///           forge script script/TestDeployOiv.s.sol:TestDeployOiv \
///             --rpc-url mainnet --broadcast \
///             --account DEPLOYER_DOT_KPK_DOT_ETH
contract TestDeployOiv is Script {
    KpkOivFactory internal constant FACTORY = KpkOivFactory(0x0d94255fdE65D302616b02A2F070CdB21190d420);

    /// @dev Disposable smoke-test EOA. NOT the production deployer — kept distinct so this test
    ///      OIV doesn't share any salt-derived addresses with future production deploys.
    address internal constant DEPLOYER = 0xDa620355C681623321962488B2ffC244d117cb25;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant FEE_RECEIVER = 0xDa620355C681623321962488B2ffC244d117cb25; // disposable test → throwaway EOA

    /// @dev Salt picked to be obviously a test, and unique vs anything we've used.
    uint256 internal constant SALT = uint256(keccak256("kpk-oiv-factory-smoke-test-v1"));

    function run() external {
        KpkOivFactory.OivConfig memory cfg = _buildConfig();

        // ── 1. Predict the 7 addresses (free, off-chain) ───────────────────────
        KpkOivFactory.OivInstance memory predicted = FACTORY.predictOivAddresses(cfg, DEPLOYER);

        console.log("==========================================");
        console.log("Predicted OIV addresses (caller =", DEPLOYER, "):");
        console.log("==========================================");
        console.log("  avatarSafe:           ", predicted.avatarSafe);
        console.log("  managerSafe:          ", predicted.managerSafe);
        console.log("  execRolesModifier:    ", predicted.execRolesModifier);
        console.log("  subRolesModifier:     ", predicted.subRolesModifier);
        console.log("  managerRolesModifier: ", predicted.managerRolesModifier);
        console.log("  kpkSharesImpl:        ", predicted.kpkSharesImpl);
        console.log("  kpkSharesProxy:       ", predicted.kpkSharesProxy);
        console.log("==========================================");

        // ── 2. Broadcast the deployOiv call ────────────────────────────────────
        vm.startBroadcast();
        KpkOivFactory.OivInstance memory actual = FACTORY.deployOiv(cfg);
        vm.stopBroadcast();

        // ── 3. Post-flight: assert prediction matches actual byte-for-byte ─────
        require(predicted.avatarSafe == actual.avatarSafe, "avatarSafe mismatch");
        require(predicted.managerSafe == actual.managerSafe, "managerSafe mismatch");
        require(predicted.execRolesModifier == actual.execRolesModifier, "execMod mismatch");
        require(predicted.subRolesModifier == actual.subRolesModifier, "subMod mismatch");
        require(predicted.managerRolesModifier == actual.managerRolesModifier, "managerMod mismatch");
        require(predicted.kpkSharesImpl == actual.kpkSharesImpl, "kpkSharesImpl mismatch");
        require(predicted.kpkSharesProxy == actual.kpkSharesProxy, "kpkSharesProxy mismatch");

        console.log("==========================================");
        console.log("[OK] Predicted addresses == actual deployed addresses");
        console.log("==========================================");
    }

    function _buildConfig() internal pure returns (KpkOivFactory.OivConfig memory cfg) {
        // Manager Safe = deployer EOA, threshold 1.
        address[] memory mgrOwners = new address[](1);
        mgrOwners[0] = DEPLOYER;

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: mgrOwners, threshold: 1});
        cfg.salt = SALT;
        cfg.admin = DEPLOYER;

        // KpkShares params. `safe` and `admin` get overridden inside _deploySharesProxy.
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: WETH,
            admin: address(0), // overridden by factory → address(this) temporarily, then transferred
            name: "TEST OIV",
            symbol: "TEST",
            safe: address(0), // overridden by factory → predicted Avatar Safe
            subscriptionRequestTtl: 86400, // 1 day
            redemptionRequestTtl: 259200, // 3 days
            feeReceiver: FEE_RECEIVER,
            managementFeeRate: 0,
            redemptionFeeRate: 0,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });

        // No additional assets — base WETH only.
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](0);
    }
}
