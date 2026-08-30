// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KpkOivFactory} from "src/KpkOivFactory.sol";
import {KpkSharesDeployer} from "src/KpkSharesDeployer.sol";
import {IKpkSharesNav} from "src/IKpkSharesNav.sol";
import {KpkSharesNav} from "src/KpkSharesNav.sol";
import {KpkSharesNavFactory} from "src/KpkSharesNavFactory.sol";
import {MockNavCalculator} from "test/mocks/MockNavCalculator.sol";
import {OivTestConstants} from "test/OivTestConstants.sol";

/// @notice Fork tests for `KpkSharesNavFactory` against mainnet Safe and Zodiac contracts.
///         Run with: forge test --match-contract KpkSharesNavFactoryTest --fork-url $MAINNET_URL
/// @dev    A fork is required rather than convenient: the factory composes the REAL
///         `KpkOivFactory.deployStack`, which deploys Safe v1.4.1 proxies and Zodiac Roles Modifier
///         v2.1.1 proxies against live singletons. Mocking that away would test the composition
///         against a fiction — and composition is the entire contract.
contract KpkSharesNavFactoryTest is OivTestConstants {
    /// @dev DAI, used as the additional (18-decimal) asset. Its decimals differ from USDC's, so the
    ///      listing gate's decimals check is genuinely exercised rather than trivially satisfied.
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    uint256 internal constant ONE_USD = 1e8;

    address internal factoryOwner = makeAddr("factoryOwner");
    address internal navFactoryOwner = makeAddr("navFactoryOwner");
    address internal managerSigner = makeAddr("managerSigner");
    address internal securityCouncil = makeAddr("securityCouncil");
    address internal admin = makeAddr("admin");
    address internal feeReceiver = makeAddr("feeReceiver");

    KpkOivFactory internal oivFactory;
    KpkSharesNavFactory internal navFactory;
    MockNavCalculator internal nav;
    address internal navImpl;

    function setUp() public {
        vm.createSelectFork(vm.envString("MAINNET_URL"));
        _requireInfraDeployed();

        // KpkSharesDeployer is factory-locked, so the factory address must be known before the
        // deployer is constructed: this contract's next nonce produces the deployer, the one after
        // it produces the factory.
        uint256 nextNonce = vm.getNonce(address(this));
        address predictedFactory = vm.computeCreateAddress(address(this), nextNonce + 1);
        KpkSharesDeployer sharesDeployer = new KpkSharesDeployer(predictedFactory);

        oivFactory = new KpkOivFactory(
            factoryOwner,
            SAFE_PROXY_FACTORY,
            SAFE_SINGLETON,
            SAFE_MODULE_SETUP,
            SAFE_FALLBACK_HANDLER,
            MODULE_PROXY_FACTORY,
            ROLES_MODIFIER_MASTERCOPY,
            address(sharesDeployer)
        );
        require(address(oivFactory) == predictedFactory, "factory address mismatch");

        nav = new MockNavCalculator();
        nav.registerAsset(USDC, 6, int256(ONE_USD), 8);
        nav.registerAsset(DAI, 18, int256(ONE_USD), 8);

        navImpl = address(new KpkSharesNav());
        navFactory = new KpkSharesNavFactory(address(oivFactory), navImpl, navFactoryOwner);
    }

    // ── The happy path ─────────────────────────────────────────────────────────

    function test_deployNavFund_deploysAllSevenContracts() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(1));

        assertTrue(inst.avatarSafe != address(0), "avatarSafe not deployed");
        assertTrue(inst.managerSafe != address(0), "managerSafe not deployed");
        assertTrue(inst.execRolesModifier != address(0), "execRolesModifier not deployed");
        assertTrue(inst.subRolesModifier != address(0), "subRolesModifier not deployed");
        assertTrue(inst.managerRolesModifier != address(0), "managerRolesModifier not deployed");
        assertEq(inst.navImpl, navImpl, "navImpl is the shared implementation");
        assertTrue(inst.navProxy != address(0), "navProxy not deployed");

        assertTrue(inst.avatarSafe.code.length > 0, "avatarSafe has no code");
        assertTrue(inst.managerSafe.code.length > 0, "managerSafe has no code");
        assertTrue(inst.execRolesModifier.code.length > 0, "execRolesModifier has no code");
        assertTrue(inst.avatarSafe != inst.managerSafe, "the two Safes must be distinct");
    }

    /// @notice The fund is priced against the Avatar Safe the same call deployed.
    /// @dev The whole point of doing this in one transaction. A fund pointed at the wrong Safe
    ///      prices itself off somebody else's book and mints against it.
    function test_deployNavFund_pointsTheFundAtItsOwnAvatarSafe() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(2));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        assertEq(fund.portfolioSafe(), inst.avatarSafe, "fund is not pointed at its own Avatar Safe");
        assertEq(fund.navCalculator(), address(nav), "NAV calculator not set");
        assertEq(fund.getApprovedAsset(USDC).asset, USDC, "base asset not listed");
    }

    /// @notice Roles land on their real holders and the factory keeps nothing.
    /// @dev Asserted POSITIVELY, not just as "the factory dropped its own". If `admin` were the
    ///      factory the grant would be a no-op and the renounce would remove the only holder,
    ///      leaving a fund nobody can administer — and a factory-only check would pass precisely
    ///      because nobody was left.
    function test_deployNavFund_handsOverEveryRole() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(3));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        assertTrue(fund.hasRole(0x00, admin), "admin does not hold DEFAULT_ADMIN_ROLE");
        assertTrue(fund.hasRole(fund.OPERATOR(), inst.managerSafe), "manager Safe does not hold OPERATOR");
        assertFalse(fund.hasRole(0x00, address(navFactory)), "factory still holds admin");
        assertFalse(fund.hasRole(fund.OPERATOR(), address(navFactory)), "factory still holds OPERATOR");
    }

    /// @notice The factory's private OPERATOR constant must equal the fund's.
    /// @dev A mismatch would grant the Manager Safe a role that does not exist while leaving the
    ///      real OPERATOR unheld — a fund that deploys cleanly and can never settle a batch. The
    ///      handover assertion above would not catch it, since it would check the same wrong value.
    function test_operatorConstantMatchesTheFund() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(4));
        assertEq(KpkSharesNav(inst.navProxy).OPERATOR(), keccak256("OPERATOR"), "OPERATOR constant drifted");
    }

    function test_deployNavFund_listsAdditionalAssets() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(5));
        KpkSharesNav fund = KpkSharesNav(inst.navProxy);

        IKpkSharesNav.ApprovedAsset memory dai = fund.getApprovedAsset(DAI);
        assertEq(dai.asset, DAI, "DAI not listed");
        assertEq(dai.decimals, 18, "DAI decimals not recorded");
        assertTrue(dai.canDeposit, "DAI not listed for deposit");
        assertTrue(dai.canRedeem, "DAI not listed for redemption");
    }

    function test_deployNavFund_recordsTheFundInTheRegistry() public {
        uint256 idBefore = navFactory.fundCount();
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(6));

        assertEq(navFactory.fundCount(), idBefore + 1, "fundCount did not advance");
        (address avatarSafe,,,,,, address navProxy) = navFactory.funds(idBefore);
        assertEq(avatarSafe, inst.avatarSafe, "registry avatarSafe mismatch");
        assertEq(navProxy, inst.navProxy, "registry navProxy mismatch");
    }

    // ── The documented gap, pinned by a test ───────────────────────────────────

    /// @notice The Avatar Safe has NOT approved the fund, so redemptions cannot pay out yet.
    /// @dev This is the one capability `deployOiv` has that this factory structurally cannot:
    ///      `deployStack` disables the factory as an Avatar Safe module before returning, so there
    ///      is no route to execute as the Safe. Asserting it keeps the limitation honest — if a
    ///      later change makes approvals happen, this test fails and the documentation gets
    ///      corrected rather than silently rotting into a false warning.
    function test_deployNavFund_leavesAvatarSafeApprovalsUnset() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(7));

        assertEq(IERC20(USDC).allowance(inst.avatarSafe, inst.navProxy), 0, "USDC allowance unexpectedly set");
        assertEq(IERC20(DAI).allowance(inst.avatarSafe, inst.navProxy), 0, "DAI allowance unexpectedly set");
    }

    // ── Determinism ────────────────────────────────────────────────────────────

    /// @notice Two callers may use the same salt without colliding.
    /// @dev The stack salt is bound to `msg.sender`. Without that, the second caller's Safe would
    ///      already exist at the derived address and the whole deployment would revert — a
    ///      permissionless factory that the first user of any given salt can grief.
    function test_sameSaltFromDifferentCallersDoesNotCollide() public {
        address callerA = makeAddr("callerA");
        address callerB = makeAddr("callerB");

        vm.prank(callerA);
        KpkSharesNavFactory.NavFundInstance memory a = navFactory.deployNavFund(_config(99));
        vm.prank(callerB);
        KpkSharesNavFactory.NavFundInstance memory b = navFactory.deployNavFund(_config(99));

        assertTrue(a.avatarSafe != b.avatarSafe, "same salt produced the same Avatar Safe");
        assertTrue(a.navProxy != b.navProxy, "same salt produced the same fund");
    }

    // ── Validation ─────────────────────────────────────────────────────────────

    function test_deployNavFund_revertsWhenAdminIsTheFactory() public {
        KpkSharesNavFactory.NavFundConfig memory config = _config(8);
        config.admin = address(navFactory);

        vm.expectRevert(KpkSharesNavFactory.AdminIsFactory.selector);
        navFactory.deployNavFund(config);
    }

    function test_deployNavFund_revertsWhenAdminIsZero() public {
        KpkSharesNavFactory.NavFundConfig memory config = _config(9);
        config.admin = address(0);

        vm.expectRevert(KpkSharesNavFactory.ZeroAddress.selector);
        navFactory.deployNavFund(config);
    }

    /// @dev Re-listing the base asset would overwrite its flags with whatever was passed, silently
    ///      disabling deposits or redemptions on the fund's own base asset.
    function test_deployNavFund_revertsWhenAnAdditionalAssetIsTheBaseAsset() public {
        KpkSharesNavFactory.NavFundConfig memory config = _config(10);
        config.additionalAssets[0].asset = USDC;

        vm.expectRevert(KpkSharesNavFactory.DuplicateAsset.selector);
        navFactory.deployNavFund(config);
    }

    function test_deployNavFund_revertsOnDuplicateAdditionalAssets() public {
        KpkSharesNavFactory.NavFundConfig memory config = _config(11);
        config.additionalAssets = new KpkOivFactory.AssetConfig[](2);
        config.additionalAssets[0] = KpkOivFactory.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});
        config.additionalAssets[1] = KpkOivFactory.AssetConfig({asset: DAI, canDeposit: true, canRedeem: false});

        vm.expectRevert(KpkSharesNavFactory.DuplicateAsset.selector);
        navFactory.deployNavFund(config);
    }

    /// @dev An asset the NAV calculator cannot price must not reach a deployed fund. The gate lives
    ///      in `KpkSharesNav.updateAsset`, so this also proves the factory does not somehow bypass it.
    function test_deployNavFund_revertsWhenAnAssetIsNotRegisteredInTheNav() public {
        nav.unregisterAsset(DAI);

        vm.expectRevert();
        navFactory.deployNavFund(_config(12));
    }

    function test_deployNavFund_revertsWhenImplementationIsUnset() public {
        KpkSharesNavFactory bare = new KpkSharesNavFactory(address(oivFactory), address(0), navFactoryOwner);

        vm.expectRevert(KpkSharesNavFactory.NavImplementationNotSet.selector);
        bare.deployNavFund(_config(13));
    }

    // ── Implementation management ──────────────────────────────────────────────

    function test_setNavImplementation_onlyOwner() public {
        address replacement = address(new KpkSharesNav());

        vm.prank(makeAddr("stranger"));
        vm.expectRevert();
        navFactory.setNavImplementation(replacement);

        vm.prank(navFactoryOwner);
        navFactory.setNavImplementation(replacement);
        assertEq(navFactory.navImplementation(), replacement, "implementation not updated");
    }

    /// @dev An EOA passes a bare non-zero check and would produce funds whose every call silently
    ///      returns nothing, so the setter requires deployed code.
    function test_setNavImplementation_rejectsAnAddressWithNoCode() public {
        vm.prank(navFactoryOwner);
        vm.expectRevert(KpkSharesNavFactory.NotAContract.selector);
        navFactory.setNavImplementation(makeAddr("notAContract"));
    }

    /// @notice Replacing the implementation must not migrate funds already deployed.
    function test_setNavImplementation_doesNotAffectExistingFunds() public {
        KpkSharesNavFactory.NavFundInstance memory inst = navFactory.deployNavFund(_config(14));

        // Constructed BEFORE the prank. A `new` in argument position is itself a call, and `prank`
        // applies to the next one it sees — inline construction would spend the prank on the
        // deployment and the setter would be called by this contract, which is not the owner.
        address replacement = address(new KpkSharesNav());
        vm.prank(navFactoryOwner);
        navFactory.setNavImplementation(replacement);

        assertEq(inst.navImpl, navImpl, "the deployed fund's recorded implementation changed");
        assertEq(KpkSharesNav(inst.navProxy).portfolioSafe(), inst.avatarSafe, "existing fund disturbed");
    }

    // ── Helpers ────────────────────────────────────────────────────────────────

    function _config(uint256 salt) internal view returns (KpkSharesNavFactory.NavFundConfig memory config) {
        address[] memory owners = new address[](1);
        owners[0] = managerSigner;

        KpkOivFactory.AssetConfig[] memory additional = new KpkOivFactory.AssetConfig[](1);
        additional[0] = KpkOivFactory.AssetConfig({asset: DAI, canDeposit: true, canRedeem: true});

        config = KpkSharesNavFactory.NavFundConfig({
            managerSafe: KpkOivFactory.SafeConfig({owners: owners, threshold: 1}),
            execRolesMod: KpkOivFactory.RolesModifierConfig({finalOwner: securityCouncil}),
            admin: admin,
            sharesParams: KpkSharesNav.ConstructorParams({
                asset: USDC,
                // Overwritten by the factory — set to obviously wrong values so a test would fail
                // loudly if the overwrite were ever dropped.
                admin: address(0xdead),
                name: "kpk NAV Fund",
                symbol: "kpkNAV",
                safe: address(0xdead),
                subscriptionRequestTtl: 1 days,
                redemptionRequestTtl: 1 days,
                feeReceiver: feeReceiver,
                managementFeeRate: 0,
                redemptionFeeRate: 0,
                performanceFeeModule: address(0),
                performanceFeeRate: 0,
                navCalculator: address(nav),
                initialSharePrice: ONE_USD
            }),
            additionalAssets: additional,
            salt: salt
        });
    }
}
