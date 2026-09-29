// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";
import {TimelockParams} from "src/interfaces/IKpkTimelockDeployer.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {MockCcipRouter} from "test/mocks/MockCcipRouter.sol";
import {
    IAny2EVMMessageReceiver
} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/interfaces/IAny2EVMMessageReceiver.sol";

/// @notice AUDIT PoC — measures the FULL `ccipReceive` frame the destination actually pays for, at
///         the worst configuration every source-side bound accepts, against the hard 3,000,000-gas
///         cap that ten of the twenty live lanes enforce.
contract CcipDestinationBudgetTest is OivTestConstants {
    uint64 constant MAINNET_SELECTOR = 5009297550715157269;

    address factoryOwner = makeAddr("factoryOwner");
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");

    KpkOivFactory factory;
    CcipOivDeployer orchestrator;
    MockCcipRouter router;
    KpkTimelockDeployer timelockDeployer;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        KpkShares sharesMastercopy = new KpkShares();
        timelockDeployer = new KpkTimelockDeployer(address(new TimelockControllerUpgradeable()));
        factory = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesMastercopy),
            address(timelockDeployer)
        );
        router = new MockCcipRouter();
        orchestrator = new CcipOivDeployer(address(this), address(factory));
        orchestrator.configure(address(router), address(0));
    }

    function _ascending(uint256 n, uint160 base) internal pure returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i = 0; i < n; i++) {
            out[i] = address(base + uint160(i) * 0x100);
        }
    }

    /// @dev The worst config every SOURCE-side bound accepts:
    ///        - `CcipOivDeployer.MAX_CCIP_MANAGER_OWNERS`  manager owners
    ///        - `KpkTimelockDeployer.MAX_ROLE_MEMBERS`     proposers AND cancellers
    ///        - `CcipOivDeployer.MAX_SHARES_CHAINS`        topology entries in the payload
    function _worstConfig() internal view returns (KpkOivFactory.OivConfig memory cfg) {
        uint256 maxOwners = orchestrator.MAX_CCIP_MANAGER_OWNERS();
        uint256 maxRole = timelockDeployer.MAX_ROLE_MEMBERS();

        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: _ascending(maxOwners, 0x50000), threshold: 1});
        cfg.salt = 0xC0FFEE;
        cfg.admin = admin;
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](0);
        cfg.execTimelock = TimelockParams({
            minDelay: 2 days, proposers: _ascending(maxRole, 0x1000000), cancellers: _ascending(maxRole, 0x9000000)
        });
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: USDC,
            admin: address(0),
            name: "Test Fund Shares",
            symbol: "kTEST",
            safe: address(0),
            subscriptionRequestTtl: 1 days,
            redemptionRequestTtl: 1 days,
            feeReceiver: feeReceiver,
            managementFeeRate: 100,
            redemptionFeeRate: 50,
            performanceFeeModule: address(0),
            performanceFeeRate: 0
        });
    }

    /// @dev `MAX_SHARES_CHAINS` entries, none of them the local chain, so `ccipReceive` accepts.
    function _maxTopology() internal view returns (CcipOivDeployer.SharesChain[] memory t) {
        uint256 n = orchestrator.MAX_SHARES_CHAINS();
        t = new CcipOivDeployer.SharesChain[](n);
        for (uint256 i = 0; i < n; i++) {
            t[i] = CcipOivDeployer.SharesChain({chainId: 1_000_000 + i, asset: USDC});
        }
    }

    function _message(KpkOivFactory.OivConfig memory cfg, CcipOivDeployer.SharesChain[] memory topology)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        KpkOivFactory.OivConfig memory eff = cfg;
        eff.sharesParams.asset = address(0);
        eff.salt = uint256(keccak256(abi.encode(eff, topology)));
        eff.sharesParams.asset = cfg.sharesParams.asset;

        uint256[] memory ids = new uint256[](topology.length);
        for (uint256 i = 0; i < topology.length; i++) {
            ids[i] = topology[i].chainId;
        }
        return Client.Any2EVMMessage({
            messageId: keccak256("msg"),
            sourceChainSelector: MAINNET_SELECTOR,
            sender: abi.encode(address(orchestrator)),
            data: abi.encode(factory.oivToStackConfig(eff), ids),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /// @notice Measures the frame with an unlimited stipend, for the record.
    function test_poc_measureFullCcipReceiveFrame() public {
        vm.chainId(8453); // a destination chain, not one the topology names
        Client.Any2EVMMessage memory m = _message(_worstConfig(), _maxTopology());

        vm.prank(address(router));
        uint256 before = gasleft();
        orchestrator.ccipReceive(m);
        uint256 spent = before - gasleft();

        emit log_named_uint("full ccipReceive frame gas", spent);
        assertLt(spent, 3_000_000, "the frame the destination pays for must fit the 3M cap");
    }

    /// @notice The real thing: CCIP calls `ccipReceive` with EXACTLY `gasLimit` gas, and 3,000,000 is
    ///         the hard ceiling on ten of the twenty live lanes. Passing means the worst permitted
    ///         config is deliverable; failing means the source burns every lane's non-refundable fee
    ///         and every destination reverts out-of-gas.
    function test_poc_deliverAtTheHard3MCap() public {
        vm.chainId(8453);
        Client.Any2EVMMessage memory m = _message(_worstConfig(), _maxTopology());

        bytes memory payload = abi.encodeCall(IAny2EVMMessageReceiver.ccipReceive, (m));

        vm.prank(address(router));
        (bool ok, bytes memory ret) = address(orchestrator).call{gas: 3_000_000}(payload);

        emit log_named_uint("returndata len", ret.length);
        assertTrue(ok, "worst permitted config must be deliverable inside the 3,000,000 gas cap");
    }
}
