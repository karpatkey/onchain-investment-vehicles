// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {OivConfigReader} from "script/base/OivConfigReader.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";

/// @dev Exposes the reader's internals. The reader is `abstract` and its helpers are `internal`, so
///      without this the only way to observe a parse would be a full fork deployment.
contract ReaderHarness is OivConfigReader {
    function oivConfig(string memory json) external view returns (KpkOivFactory.OivConfig memory) {
        return _buildOivConfig(json);
    }

    function stackConfig(string memory json) external view returns (KpkOivFactory.StackConfig memory) {
        return _buildStackConfig(json);
    }

    function sharesChains(string memory json) external view returns (CcipOivDeployer.SharesChain[] memory) {
        return _buildSharesChains(json);
    }

    function shouldDeployShares(string memory json) external view returns (bool) {
        return _shouldDeployShares(json);
    }
}

/// @notice Pins that the deploy path actually carries the timelock, per-chain asset and chain
///         selection into the factory's structs.
///
///         Every one of these would have passed vacuously before: the reader built the structs field
///         by field and simply never assigned the timelock fields, so they stayed zero — and
///         `minDelay == 0` is the factory's "no timelock" sentinel. A fund the operator believed was
///         timelocked deployed with `admin` holding total control, with no error and no warning.
contract OivConfigReaderTest is Test {
    ReaderHarness reader;
    string json;

    address constant GOV = 0x8b884f80B3B839F52b6cE168f133e7a5D1f0A537;
    address constant SUPERADMIN = 0xAa5A7C7Ea51F276301f881F9CCB501a1dFeF4F72;
    address constant VETO = 0x6F2A3D35Ff275d6B76dB47eFB0Da1b2358daf11b;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant GNOSIS_ASSET = 0x2a22f9c3b484c3629090FeED35F17Ff8F88f76F0;

    function setUp() public {
        reader = new ReaderHarness();
        json = vm.readFile("script/oiv-config.example.json");
    }

    function test_oivConfig_carriesBothTimelocks() public view {
        KpkOivFactory.OivConfig memory c = reader.oivConfig(json);

        assertEq(c.execTimelock.minDelay, 2 days, "exec delay");
        assertEq(c.execTimelock.proposers.length, 2, "exec proposers");
        assertEq(c.execTimelock.proposers[0], GOV);
        assertEq(c.execTimelock.proposers[1], SUPERADMIN);
        assertEq(c.execTimelock.cancellers.length, 1, "exec cancellers");
        assertEq(c.execTimelock.cancellers[0], VETO);

        assertEq(c.sharesTimelock.minDelay, 7 days, "shares delay");
        assertEq(c.sharesTimelock.cancellers[0], VETO, "shares canceller");
    }

    /// @dev The sidechain payload must read the SAME block as the mainnet one, or the timelock lands
    ///      at a different address there — its address is a function of these parameters.
    function test_stackConfig_carriesTheSameExecTimelock() public view {
        KpkOivFactory.OivConfig memory oiv = reader.oivConfig(json);
        KpkOivFactory.StackConfig memory stack = reader.stackConfig(json);

        assertEq(stack.execTimelock.minDelay, oiv.execTimelock.minDelay, "delay must match");
        assertEq(stack.execTimelock.proposers.length, oiv.execTimelock.proposers.length, "proposers must match");
        assertEq(stack.execTimelock.cancellers[0], oiv.execTimelock.cancellers[0], "cancellers must match");
    }

    function test_asset_usesThePerChainOverrideWhenPresent() public {
        vm.chainId(1);
        assertEq(reader.oivConfig(json).sharesParams.asset, USDC, "mainnet falls back to the default asset");

        vm.chainId(100);
        assertEq(reader.oivConfig(json).sharesParams.asset, GNOSIS_ASSET, "gnosis uses its override");

        vm.chainId(42161);
        assertEq(reader.oivConfig(json).sharesParams.asset, USDC, "a chain with no override falls back");
    }

    function test_sharesChains_selectsWhichChainsGetShares() public {
        vm.chainId(1);
        assertTrue(reader.shouldDeployShares(json), "mainnet is listed");
        vm.chainId(100);
        assertTrue(reader.shouldDeployShares(json), "gnosis is listed");
        vm.chainId(42161);
        assertFalse(reader.shouldDeployShares(json), "arbitrum is not listed - stack only");
    }

    /// @notice The CCIP path must NOT default the topology to "the chain this happens to run on":
    ///         that makes the salt origin-dependent, which is the very defect the salt-bound topology
    ///         exists to remove. The direct factory path has no such problem and keeps its default.
    function test_buildSharesChains_requiresAnExplicitTopology() public {
        string memory legacy = vm.readFile("script/ccip-test-fund-config.json");
        vm.expectRevert(
            bytes(
                "config: .sharesChains is required for the CCIP path - a per-chain default would make the salt origin-dependent"
            )
        );
        reader.sharesChains(legacy);
    }

    /// @dev A config predating these fields must keep deploying exactly as it did.
    function test_absentBlocksMeanNoTimelockAndNoRestriction() public {
        string memory legacy = vm.readFile("script/ccip-test-fund-config.json");
        KpkOivFactory.OivConfig memory c = reader.oivConfig(legacy);

        assertEq(c.execTimelock.minDelay, 0, "absent block is the no-timelock sentinel");
        assertEq(c.sharesTimelock.minDelay, 0, "absent block is the no-timelock sentinel");
        assertEq(c.execTimelock.proposers.length, 0);
        vm.chainId(42161);
        assertTrue(reader.shouldDeployShares(legacy), "absent sharesChains leaves the choice to the caller");
    }
}
