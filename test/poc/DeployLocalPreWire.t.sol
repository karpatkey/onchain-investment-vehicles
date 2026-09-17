// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkTimelockDeployer} from "src/KpkTimelockDeployer.sol";
import {KpkShares} from "src/kpkShares.sol";
import {
    TimelockControllerUpgradeable
} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {CcipOivDeployer} from "src/CcipOivDeployer.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";
import {MockCcipRouter} from "test/mocks/MockCcipRouter.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";
import {IRoles} from "src/interfaces/IRoles.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice REGRESSION — `deployLocal` is new in this PR and is the first permissionless way for a
///         third party to make the orchestrator call `factory.deployStack` on a destination chain.
///         Because the orchestrator is the factory's uniform caller, anyone who has seen a fund's
///         `(config, sharesChains)` — public the moment `deployEverywhere` enters the mempool — can
///         pre-wire that fund's stack on each destination. A strict `deployStack` on the receive
///         path then reverted `StackAlreadyDeployedHere` for ever, and every lane's non-refundable
///         fee was lost; destination gas on an L2 is cheap against the source fee for a 3M-gas
///         execution, so the economics favoured the griefer.
///
///         `ccipReceive` is now IDEMPOTENT: a stack already present at the fund's canonical
///         addresses is reported as delivered. Sound because the pre-wired stack IS this fund's
///         stack — the salt binds the whole config, and the one field left out (the base asset) the
///         stack half never reads, so nobody can wire different owners or a different admin there
///         without moving the addresses.
contract DeployLocalPreWireTest is OivTestConstants {
    uint64 constant MAINNET_SELECTOR = 5009297550715157269;
    uint256 constant BASE_CHAIN_ID = 8453;
    uint256 constant FEE = 1 ether;

    address factoryOwner = makeAddr("factoryOwner");
    address managerSigner = makeAddr("managerSigner");
    address admin = makeAddr("admin");
    address feeReceiver = makeAddr("feeReceiver");
    address griefer = makeAddr("griefer");

    KpkOivFactory factory;
    CcipOivDeployer orchestrator;
    MockCcipRouter router;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        KpkShares sharesMastercopy = new KpkShares();
        KpkTimelockDeployer timelockDeployer = new KpkTimelockDeployer(address(new TimelockControllerUpgradeable()));
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
        router.setFee(FEE);
        orchestrator = new CcipOivDeployer(address(this), address(factory));
        orchestrator.configure(address(router), address(0));
        vm.deal(address(this), 1_000 ether);
        vm.deal(griefer, 1_000 ether);
    }

    function _config(address asset) internal view returns (KpkOivFactory.OivConfig memory cfg) {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;
        cfg.managerSafe = KpkOivFactory.SafeConfig({owners: owners, threshold: 1});
        cfg.salt = 42;
        cfg.admin = admin;
        cfg.additionalAssets = new KpkOivFactory.AssetConfig[](0);
        cfg.sharesParams = KpkShares.ConstructorParams({
            asset: asset,
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

    function _topology() internal pure returns (CcipOivDeployer.SharesChain[] memory t) {
        t = new CcipOivDeployer.SharesChain[](1);
        t[0] = CcipOivDeployer.SharesChain({chainId: 1, asset: USDC});
    }

    function _message(KpkOivFactory.OivConfig memory cfg) internal view returns (Client.Any2EVMMessage memory) {
        CcipOivDeployer.SharesChain[] memory topology = _topology();
        KpkOivFactory.OivConfig memory eff = cfg;
        eff.sharesParams.asset = address(0);
        eff.salt = uint256(keccak256(abi.encode(eff, topology)));
        eff.sharesParams.asset = cfg.sharesParams.asset;

        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        return Client.Any2EVMMessage({
            messageId: keccak256("msg"),
            sourceChainSelector: MAINNET_SELECTOR,
            sender: abi.encode(address(orchestrator)),
            data: abi.encode(factory.oivToStackConfig(eff), ids),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /// @notice A stranger pre-wires the fund's stack on a destination chain; the fund's own,
    ///         already-paid-for CCIP delivery then reverts permanently.
    function test_strangerPreWireNoLongerKillsTheDelivery() public {
        KpkOivFactory.OivConfig memory victim = _config(USDC);

        vm.chainId(BASE_CHAIN_ID); // a destination chain under this topology

        KpkOivFactory.OivInstance memory predicted = orchestrator.predictOiv(victim, _topology());

        // The griefer does not even need the fund's BASE ASSET: `_effectiveConfig` zeroes it before
        // hashing, so any non-zero placeholder reproduces the same salt and the same addresses.
        KpkOivFactory.OivConfig memory forged = _config(DAI_PLACEHOLDER);

        vm.prank(griefer);
        KpkOivFactory.OivInstance memory landed = orchestrator.deployLocal(forged, _topology());

        assertEq(landed.avatarSafe, predicted.avatarSafe, "griefer landed the fund's canonical Avatar Safe");
        assertEq(landed.execRolesModifier, predicted.execRolesModifier, "and its canonical exec modifier");
        assertEq(IRoles(predicted.execRolesModifier).owner(), admin, "and it is fully WIRED, not merely occupied");

        // The fund's own message — already paid for, non-refundably, on the source chain — must now
        // SUCCEED, reporting the stack that is already there. Before the fix this reverted
        // `StackAlreadyDeployedHere`, and CCIP manual re-execution replayed that revert for ever.
        Client.Any2EVMMessage memory m = _message(victim);
        vm.prank(address(router));
        orchestrator.ccipReceive(m);

        // And it reported the fund's real addresses, not zeros: the delivery is indistinguishable
        // from one that deployed the stack itself, which is the point.
        vm.recordLogs();
        vm.prank(address(router));
        orchestrator.ccipReceive(m);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertGt(logs.length, 0, "a delivery that finds the stack present must still emit StackReceived");
    }

    address constant DAI_PLACEHOLDER = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    receive() external payable {}
}
