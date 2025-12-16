// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "test/constants.sol";
import "src/kpkShares.sol";
import "src/IkpkShares.sol";
import "src/FeeModules/IPerfFeeModule.sol";
import "test/mocks/tokens.sol";
import "test/errors.sol";
import "src/FeeModules/WatermarkFee.sol";
import {UnsafeUpgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

// Mock price oracle for testing
contract MockPriceOracle is AggregatorV3Interface {
    int256 public price;
    uint8 public _decimals;

    constructor(int256 price_, uint8 decimals_) {
        price = price_;
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "Mock Price Oracle";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(
        uint80 // _roundId
    )
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (1, price, block.timestamp, block.timestamp, 1);
    }
}

/// @notice Base test contract for kpkShares functionality
/// @dev All domain-specific test contracts should inherit from this
contract kpkSharesTestBase is Test {
    KpkShares public kpkSharesContract;

    // Test accounts
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address admin = makeAddr("admin");
    address ops = makeAddr("ops");
    address safe = makeAddr("safe");
    address feeRecipient = makeAddr("feeRecipient");

    // Tokens and oracles
    Mock_ERC20 public usdc;
    IPerfFeeModule public perfFeeModule;
    MockPriceOracle public mockUSDCOracle;
    // Global constants for child contracts (maintaining same nomenclature as getters)
    uint64 public constant SUBSCRIPTION_REQUEST_TTL = 1 days;
    uint64 public constant REDEMPTION_REQUEST_TTL = 1 days;
    uint64 public constant SUBSCRIPTION_TTL = 1 days; // Alias for SUBSCRIPTION_REQUEST_TTL
    uint64 public constant REDEMPTION_TTL = 1 days; // Alias for REDEMPTION_REQUEST_TTL
    uint256 public constant MANAGEMENT_FEE_RATE = 100; // 1% in basis points
    uint256 public constant REDEMPTION_FEE_RATE = 50; // 0.5% in basis points
    uint256 public constant PERFORMANCE_FEE_RATE = 1000; // 10% in basis points
    uint256 public constant SHARES_PRICE = 1e8; // 1:1 price

    function setUp() public virtual {
        usdc = new Mock_ERC20("USDC", 6);

        // Deploy mock price oracle with USDC price of $1.00 (8 decimals)
        mockUSDCOracle = new MockPriceOracle(1e8, 8); // $1.00 = 1000000000000

        usdc.mint(address(alice), _usdcAmount(2_000_000)); // 2M USDC for large amount tests
        usdc.mint(address(bob), _usdcAmount(1000));
        usdc.mint(address(carol), _usdcAmount(1000));
        usdc.mint(address(ops), _usdcAmount(1000));
        usdc.mint(address(safe), _usdcAmount(100_000));

        // Deploy mock performance fee module
        perfFeeModule = new WatermarkFee();

        // Deploy kpkShares as a proxy
        address kpkSharesImpl = address(new KpkShares());
        address kpkSharesProxy = UnsafeUpgrades.deployUUPSProxy(
            kpkSharesImpl,
            abi.encodeCall(
                KpkShares.initialize,
                (
                    KpkShares.ConstructorParams({
                        asset: address(usdc),
                        admin: admin,
                        name: "kpk",
                        symbol: "kpk",
                        safe: safe,
                        subscriptionRequestTtl: SUBSCRIPTION_REQUEST_TTL,
                        redemptionRequestTtl: REDEMPTION_REQUEST_TTL,
                        feeReceiver: feeRecipient,
                        managementFeeRate: MANAGEMENT_FEE_RATE,
                        redemptionFeeRate: REDEMPTION_FEE_RATE,
                        performanceFeeModule: address(perfFeeModule),
                        performanceFeeRate: PERFORMANCE_FEE_RATE
                    })
                )
            )
        );
        kpkSharesContract = KpkShares(kpkSharesProxy);

        // Grant allowance for the main contract to spend USDC from the safe for redemptions
        vm.prank(safe);
        usdc.approve(address(kpkSharesContract), type(uint256).max);

        // Grant operator role
        vm.prank(admin);
        kpkSharesContract.grantRole(OPERATOR, ops);

        // Setup allowances
        usdc.approve(address(kpkSharesContract), type(uint256).max);
        vm.prank(alice);
        usdc.approve(address(kpkSharesContract), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(kpkSharesContract), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(kpkSharesContract), type(uint256).max);
        vm.prank(safe);
        usdc.approve(address(kpkSharesContract), type(uint256).max);

        // Setup labels
        vm.label(address(usdc), "USDC");
        vm.label(address(mockUSDCOracle), "mockUSDCOracle");
    }

    // ============================================================================
    // Helper Functions
    // ============================================================================

    /// @notice Convert USDC amount to proper decimals
    function _usdcAmount(uint256 i) internal pure returns (uint256) {
        return i * 1e6;
    }

    /// @notice Convert shares amount to proper decimals
    function _sharesAmount(uint256 i) internal pure returns (uint256) {
        return i * 1e18;
    }

    /// @notice Helper function to deploy a new KpkShares contract with custom fee parameters
    function _deployKpkSharesWithFees(uint256 managementFeeRate, uint256 redemptionFeeRate, uint256 performanceFeeRate)
        internal
        returns (KpkShares)
    {
        address kpkSharesImpl = address(new KpkShares());
        address kpkSharesProxy = UnsafeUpgrades.deployUUPSProxy(
            kpkSharesImpl,
            abi.encodeCall(
                KpkShares.initialize,
                (
                    KpkShares.ConstructorParams({
                        asset: address(usdc),
                        admin: admin,
                        name: "kpk",
                        symbol: "kpk",
                        safe: safe,
                        subscriptionRequestTtl: SUBSCRIPTION_REQUEST_TTL,
                        redemptionRequestTtl: REDEMPTION_REQUEST_TTL,
                        feeReceiver: feeRecipient,
                        managementFeeRate: managementFeeRate,
                        redemptionFeeRate: redemptionFeeRate,
                        performanceFeeModule: address(perfFeeModule),
                        performanceFeeRate: performanceFeeRate
                    })
                )
            )
        );
        KpkShares kpkSharesWithFees = KpkShares(kpkSharesProxy);

        // Grant operator role
        vm.prank(admin);
        kpkSharesWithFees.grantRole(OPERATOR, ops);

        // Grant allowance for the new contract to spend USDC from the safe for redemptions
        vm.prank(safe);
        usdc.approve(address(kpkSharesWithFees), type(uint256).max);

        // Setup allowances
        vm.prank(alice);
        usdc.approve(address(kpkSharesWithFees), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(kpkSharesWithFees), type(uint256).max);
        vm.prank(carol);
        usdc.approve(address(kpkSharesWithFees), type(uint256).max);

        return kpkSharesWithFees;
    }

    /// @notice Helper function to test request processing with common setup
    function _testRequestProcessing(
        bool isSubscription,
        address user,
        uint256 amount,
        uint256 price,
        bool shouldApprove
    ) internal returns (uint256 requestId) {
        if (isSubscription) {
            // Calculate shares using the preview function
            uint256 sharesOut = kpkSharesContract.assetsToShares(amount, price, address(usdc));
            vm.startPrank(user);
            requestId = kpkSharesContract.requestSubscription(amount, sharesOut, address(usdc), user);
            vm.stopPrank();
        } else {
            // For redeem, we need shares first - create shares for testing
            _createSharesForTesting(user, amount);
            // Calculate assets using the preview function
            uint256 assetsOut = kpkSharesContract.sharesToAssets(amount, price, address(usdc));
            vm.startPrank(user);
            requestId = kpkSharesContract.requestRedemption(amount, assetsOut, address(usdc), user);
            vm.stopPrank();
        }

        if (shouldApprove) {
            vm.prank(ops);
            if (isSubscription) {
                uint256[] memory approveRequests = new uint256[](1);
                approveRequests[0] = requestId;
                uint256[] memory rejectRequests = new uint256[](0);
                kpkSharesContract.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);
            } else {
                uint256[] memory approveRequests = new uint256[](1);
                approveRequests[0] = requestId;
                uint256[] memory rejectRequests = new uint256[](0);
                kpkSharesContract.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);
            }
        }

        return requestId;
    }

    /// @notice Helper function to test fee charging scenarios
    function _testFeeCharging(
        uint256 managementFeeRate,
        uint256 redemptionFeeRate,
        uint256 performanceFeeRate,
        uint256 shares,
        uint256 timeElapsed
    ) internal returns (uint256 requestId) {
        // Deploy contract with custom fees
        KpkShares kpkSharesWithFees = _deployKpkSharesWithFees(managementFeeRate, redemptionFeeRate, performanceFeeRate);

        // Create shares for testing
        _createSharesForTestingWithContract(kpkSharesWithFees, alice, shares);

        // Create redeem request
        // Calculate assets using the preview function
        uint256 assetsOut = kpkSharesWithFees.sharesToAssets(shares, SHARES_PRICE, address(usdc));
        vm.startPrank(alice);
        requestId = kpkSharesWithFees.requestRedemption(shares, assetsOut, address(usdc), alice);
        vm.stopPrank();

        // Skip time to allow fee calculation
        skip(timeElapsed);

        // Process the request
        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesWithFees.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        return requestId;
    }

    /// @notice Helper function to test edge cases with different amounts
    function _testEdgeCaseAmounts(bool isSubscription, address user, uint256[] memory amounts, uint256 price)
        internal
        returns (uint256[] memory requestIds)
    {
        requestIds = new uint256[](amounts.length);

        for (uint256 i = 0; i < amounts.length; i++) {
            if (isSubscription) {
                // Calculate shares using the preview function
                uint256 sharesOut = kpkSharesContract.assetsToShares(amounts[i], price, address(usdc));
                vm.startPrank(user);
                requestIds[i] = kpkSharesContract.requestSubscription(amounts[i], sharesOut, address(usdc), user);
                vm.stopPrank();
            } else {
                _createSharesForTesting(user, amounts[i]);
                // Calculate assets using the preview function
                uint256 assetsOut = kpkSharesContract.sharesToAssets(amounts[i], price, address(usdc));
                vm.startPrank(user);
                requestIds[i] = kpkSharesContract.requestRedemption(amounts[i], assetsOut, address(usdc), user);
                vm.stopPrank();
            }
        }

        return requestIds;
    }

    /// @notice Helper function to create shares for testing by processing a subscription
    function _createSharesForTesting(address investor, uint256 sharesAmount) internal returns (uint256) {
        uint256 assets = kpkSharesContract.previewRedemption(sharesAmount, SHARES_PRICE, address(usdc));
        usdc.mint(address(investor), assets);

        // Approve the contract to spend USDC
        vm.prank(investor);
        usdc.approve(address(kpkSharesContract), type(uint256).max);

        // Use the original sharesAmount directly instead of recalculating
        vm.startPrank(investor);
        uint256 requestId = kpkSharesContract.requestSubscription(assets, sharesAmount, address(usdc), investor);
        vm.stopPrank();

        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        kpkSharesContract.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        // Approve the contract to spend the investor's shares for redemption
        vm.prank(investor);
        kpkSharesContract.approve(address(kpkSharesContract), sharesAmount);

        return requestId;
    }

    /// @notice Helper function to create shares for testing on a specific contract instance
    function _createSharesForTestingWithContract(KpkShares contractInstance, address investor, uint256 sharesAmount)
        internal
        returns (uint256)
    {
        uint256 assets = contractInstance.previewRedemption(sharesAmount, SHARES_PRICE, address(usdc));
        usdc.mint(address(investor), assets);

        // Approve the new contract instance to spend USDC
        vm.prank(investor);
        usdc.approve(address(contractInstance), type(uint256).max);

        // Use the original sharesAmount directly instead of recalculating
        vm.startPrank(investor);
        uint256 requestId = contractInstance.requestSubscription(assets, sharesAmount, address(usdc), investor);
        vm.stopPrank();

        vm.prank(ops);
        uint256[] memory approveRequests = new uint256[](1);
        approveRequests[0] = requestId;
        uint256[] memory rejectRequests = new uint256[](0);
        contractInstance.processRequests(approveRequests, rejectRequests, address(usdc), SHARES_PRICE);

        // Approve the contract to spend the investor's shares for redemption
        vm.prank(investor);
        contractInstance.approve(address(contractInstance), sharesAmount);

        return requestId;
    }
}
