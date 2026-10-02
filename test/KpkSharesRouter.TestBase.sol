// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {kpkSharesTestBase} from "test/kpkShares.TestBase.sol";
import {OPERATOR} from "test/constants.sol";
import {KpkSharesRouter} from "src/periphery/KpkSharesRouter.sol";
import {
    IKpkSharesRouter,
    NAV_ATTESTATION_TYPEHASH,
    REDEMPTION_INTENT_TYPEHASH
} from "src/periphery/IKpkSharesRouter.sol";

/// @notice Shared fixture for the router suites.
/// @dev    Domain separator and struct hashes are rebuilt here from first principles rather than read
///         back from the router, so a change to the EIP-712 domain or either type hash breaks these
///         tests instead of silently invalidating every signature the pricing service has issued.
contract KpkSharesRouterTestBase is kpkSharesTestBase {
    KpkSharesRouter public router;

    /// @dev The pricing service key. Its address holds `NAV_SIGNER_ROLE`.
    address internal navSigner;
    uint256 internal navSignerPk;

    /// @dev A key that holds no role, for negative signature tests.
    address internal rogueSigner;
    uint256 internal rogueSignerPk;

    /// @dev Share owners with known keys, needed to sign redemption intents.
    address internal investor;
    uint256 internal investorPk;
    address internal investor2;
    uint256 internal investor2Pk;

    /// @dev The automation account holding `RELAYER_ROLE`.
    address internal bot = makeAddr("bot");

    /// @dev Monotonically increasing NAV round, so successive quotes in one test remain valid.
    uint256 internal navRound = 1;

    uint64 internal constant MAX_NAV_TTL = 120;
    uint16 internal constant MAX_DEVIATION_BPS = 500;
    uint16 internal constant MAX_FEE_DILUTION_BPS = 50;
    uint256 internal constant PRICE_FLOOR = 0.5e8;
    uint256 internal constant PRICE_CEIL = 2e8;

    function setUp() public virtual override {
        super.setUp();

        (navSigner, navSignerPk) = makeAddrAndKey("navSigner");
        (rogueSigner, rogueSignerPk) = makeAddrAndKey("rogueSigner");
        (investor, investorPk) = makeAddrAndKey("routerInvestor");
        (investor2, investor2Pk) = makeAddrAndKey("routerInvestor2");

        router = new KpkSharesRouter(address(kpkSharesContract), admin, ops);

        // The one wiring step that matters in production too.
        vm.prank(admin);
        kpkSharesContract.grantRole(OPERATOR, address(router));

        vm.startPrank(admin);
        router.grantRole(router.NAV_SIGNER_ROLE(), navSigner);
        router.grantRole(router.RELAYER_ROLE(), bot);
        router.setAssetConfig(address(usdc), _defaultConfig());
        vm.stopPrank();

        // Fund the router's users and approve the router (not the shares contract) for subscriptions.
        usdc.mint(investor, _usdcAmount(1_000_000));
        usdc.mint(investor2, _usdcAmount(1_000_000));

        vm.prank(investor);
        usdc.approve(address(router), type(uint256).max);
        vm.prank(investor2);
        usdc.approve(address(router), type(uint256).max);

        // Give the Safe deep liquidity so redemption payouts are never the binding constraint.
        usdc.mint(safe, _usdcAmount(5_000_000));

        vm.label(address(router), "KpkSharesRouter");
    }

    // ============================================================================
    // Config
    // ============================================================================

    function _defaultConfig() internal view returns (IKpkSharesRouter.AssetConfig memory) {
        return IKpkSharesRouter.AssetConfig({
            subscribeEnabled: true,
            redeemEnabled: true,
            maxNavTtl: MAX_NAV_TTL,
            minHoldingPeriod: 0,
            maxDeviationBps: MAX_DEVIATION_BPS,
            maxFeeDilutionBps: MAX_FEE_DILUTION_BPS,
            priceFloor: PRICE_FLOOR,
            priceCeil: PRICE_CEIL,
            maxAssetsInPerTx: _usdcAmount(1_000_000),
            maxSharesInPerTx: _sharesAmount(1_000_000),
            maxSharesMintedPerDay: _sharesAmount(5_000_000),
            maxAssetsOutPerDay: _usdcAmount(5_000_000)
        });
    }

    // ============================================================================
    // NAV attestations
    // ============================================================================

    /// @notice A well-formed quote for `asset` at `price`, valid for 60 seconds from now.
    function _nav(address asset, uint256 price) internal returns (IKpkSharesRouter.NavAttestation memory) {
        return IKpkSharesRouter.NavAttestation({
            fund: address(kpkSharesContract),
            asset: asset,
            sharesPrice: price,
            navRound: navRound++,
            issuedAt: uint64(block.timestamp),
            validUntil: uint64(block.timestamp + 60)
        });
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KpkSharesRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
    }

    function _navDigest(IKpkSharesRouter.NavAttestation memory nav) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                NAV_ATTESTATION_TYPEHASH,
                nav.fund,
                nav.asset,
                nav.sharesPrice,
                nav.navRound,
                nav.issuedAt,
                nav.validUntil
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice Signs a quote with the authorised pricing key.
    function _signNav(IKpkSharesRouter.NavAttestation memory nav) internal view returns (bytes memory) {
        return _signNavWith(nav, navSignerPk);
    }

    /// @notice Signs a quote with an arbitrary key, for negative tests.
    function _signNavWith(IKpkSharesRouter.NavAttestation memory nav, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _navDigest(nav));
        return abi.encodePacked(r, s, v);
    }

    // ============================================================================
    // Redemption intents
    // ============================================================================

    function _intent(address owner, address asset, uint256 sharesIn, uint256 minAssetsOut)
        internal
        view
        returns (IKpkSharesRouter.RedemptionIntent memory)
    {
        return IKpkSharesRouter.RedemptionIntent({
            fund: address(kpkSharesContract),
            owner: owner,
            receiver: owner,
            asset: asset,
            sharesIn: sharesIn,
            minAssetsOut: minAssetsOut,
            nonce: 0,
            epoch: router.intentEpoch(owner),
            deadline: uint64(block.timestamp + 1 hours)
        });
    }

    function _intentDigest(IKpkSharesRouter.RedemptionIntent memory intent) internal view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                REDEMPTION_INTENT_TYPEHASH,
                intent.fund,
                intent.owner,
                intent.receiver,
                intent.asset,
                intent.sharesIn,
                intent.minAssetsOut,
                intent.nonce,
                intent.epoch,
                intent.deadline
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    function _signIntent(IKpkSharesRouter.RedemptionIntent memory intent, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _intentDigest(intent));
        return abi.encodePacked(r, s, v);
    }

    // ============================================================================
    // Flow helpers
    // ============================================================================

    /// @notice Subscribes `assetsIn` of USDC for `who` at `price` through the router.
    function _routerSubscribe(address who, uint256 assetsIn, uint256 price)
        internal
        returns (uint256 requestId, uint256 sharesOut)
    {
        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), price);
        bytes memory sig = _signNav(nav);

        vm.prank(who);
        return router.subscribe(address(usdc), assetsIn, 1, who, nav, sig);
    }

    /// @notice Gives `who` shares through the router and approves the router to spend them.
    function _routerSubscribeAndApproveShares(address who, uint256 assetsIn, uint256 price)
        internal
        returns (uint256 sharesOut)
    {
        (, sharesOut) = _routerSubscribe(who, assetsIn, price);

        vm.prank(who);
        kpkSharesContract.approve(address(router), type(uint256).max);
    }

    /// @notice Redeems `sharesIn` for `owner` at `price` through the router, as the bot would.
    function _routerRedeem(address owner, uint256 ownerPk, uint256 sharesIn, uint256 price)
        internal
        returns (uint256 requestId, uint256 assetsOut)
    {
        IKpkSharesRouter.RedemptionIntent memory intent = _intent(owner, address(usdc), sharesIn, 1);
        bytes memory intentSig = _signIntent(intent, ownerPk);

        IKpkSharesRouter.NavAttestation memory nav = _nav(address(usdc), price);
        bytes memory navSig = _signNav(nav);

        vm.prank(bot);
        return router.redeem(intent, intentSig, nav, navSig);
    }
}
