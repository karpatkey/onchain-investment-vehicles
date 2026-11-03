// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INavCalculator} from "../../src/interfaces/INavCalculator.sol";

/// @title MockNavCalculator
/// @notice Test double for karpatkey's `NAVCalculator`, with every health signal independently
///         settable so a fund's fail-closed behaviour can be driven from a test.
/// @dev Deliberately mirrors the real contract's awkward edges rather than an idealised version:
///      `getPriceData` REVERTS for an unregistered asset or one with no feed (the real one throws
///      `AssetNotFound` / `PriceFeedNotSet`), `getRegisteredAsset` never reverts and reports a
///      `found` flag, and a price feed carries its own `decimals` rather than being fixed at 8.
contract MockNavCalculator {
    /// @notice Thrown where the real calculator throws `AssetNotFound`
    error AssetNotFound();

    /// @notice Thrown where the real calculator throws `PriceFeedNotSet`
    error PriceFeedNotSet();

    /// @notice Thrown to simulate the real calculator running out of gas mid-scan
    error AdapterGasExhausted();

    struct FeedConfig {
        int256 price;
        uint8 decimals;
        bool stale;
        bool sequencerDown;
        bool irregular;
        bool reverts;
        bool set;
    }

    /// @notice NAV returned for any account, in USD with 8 decimals
    int256 public navValue;

    /// @notice Health flags applied to every NAV snapshot
    bool public sequencerDown;
    bool public quoteAssetStale;
    bool public quoteAssetIrregular;

    /// @notice When true, `getAccountNav` reverts as a gas-starved scan would
    bool public navReverts;

    /// @notice Assets reported in each of the NAV snapshot's three trouble arrays
    address[] internal _staleAssets;
    address[] internal _irregularAssets;
    address[] internal _monitorsUnhealthyAssets;

    mapping(address => bool) internal _registered;
    mapping(address => uint8) internal _registeredDecimals;
    mapping(address => FeedConfig) internal _feeds;

    /// @notice NAV reported only for this account; every other account reads as zero
    /// @dev The fund must read the NAV for its portfolio safe. Scoping the value here means a fund
    ///      that queried the wrong account would see 0 and revert, rather than silently passing.
    ///      `getAccountNav` cannot record the caller's argument instead: the interface declares it
    ///      `view`, so the fund reaches it by STATICCALL and any storage write would revert.
    address public navAccount;

    function setNavAccount(address account) external {
        navAccount = account;
    }

    /// @notice When set, the NAV additionally reflects this token's live balance at `navAccount`
    /// @dev Without this, `navValue` is a stored scalar that no token movement can change — which
    ///      makes any test claiming to verify "priced BEFORE the assets move" vacuous, since the
    ///      reported NAV is identical either way. Tracking a real balance is what gives those tests
    ///      teeth. Off by default so the scalar-NAV tests keep their simple arithmetic.
    address public balanceToken;

    /// @notice Multiplier converting one unit of `balanceToken` into USD with 8 decimals
    uint256 public balanceScale;

    function trackBalance(address token, uint256 scale) external {
        balanceToken = token;
        balanceScale = scale;
    }

    function setNavValue(int256 value) external {
        navValue = value;
    }

    function setNavReverts(bool value) external {
        navReverts = value;
    }

    function setSequencerDown(bool value) external {
        sequencerDown = value;
    }

    function setQuoteAssetStale(bool value) external {
        quoteAssetStale = value;
    }

    function setQuoteAssetIrregular(bool value) external {
        quoteAssetIrregular = value;
    }

    function pushStaleAsset(address asset) external {
        _staleAssets.push(asset);
    }

    function pushIrregularAsset(address asset) external {
        _irregularAssets.push(asset);
    }

    function pushMonitorsUnhealthyAsset(address asset) external {
        _monitorsUnhealthyAssets.push(asset);
    }

    function clearTroubleArrays() external {
        delete _staleAssets;
        delete _irregularAssets;
        delete _monitorsUnhealthyAssets;
    }

    /// @notice Registers an asset and gives it a healthy feed in one step
    function registerAsset(address asset, uint8 decimals_, int256 price, uint8 priceDecimals) external {
        _registered[asset] = true;
        _registeredDecimals[asset] = decimals_;
        _feeds[asset] = FeedConfig({
            price: price,
            decimals: priceDecimals,
            stale: false,
            sequencerDown: false,
            irregular: false,
            reverts: false,
            set: true
        });
    }

    /// @notice Registers an asset WITHOUT a price feed, as the real registry permits
    function registerAssetWithoutFeed(address asset, uint8 decimals_) external {
        _registered[asset] = true;
        _registeredDecimals[asset] = decimals_;
    }

    function unregisterAsset(address asset) external {
        _registered[asset] = false;
        delete _feeds[asset];
    }

    /// @notice Overrides the decimals the registry reports, to drive the listing cross-check
    function setRegisteredDecimals(address asset, uint8 decimals_) external {
        _registeredDecimals[asset] = decimals_;
    }

    function setPrice(address asset, int256 price, uint8 priceDecimals) external {
        _feeds[asset].price = price;
        _feeds[asset].decimals = priceDecimals;
        _feeds[asset].set = true;
    }

    function setPriceStale(address asset, bool value) external {
        _feeds[asset].stale = value;
    }

    function setPriceSequencerDown(address asset, bool value) external {
        _feeds[asset].sequencerDown = value;
    }

    function setPriceIrregular(address asset, bool value) external {
        _feeds[asset].irregular = value;
    }

    function setPriceReverts(address asset, bool value) external {
        _feeds[asset].reverts = value;
    }

    //
    // INavCalculator surface
    //

    function getAccountNav(address account, address quoteAsset) external view returns (INavCalculator.NAV memory nav) {
        if (navReverts) revert AdapterGasExhausted();

        bool scoped = navAccount == address(0) || navAccount == account;
        nav.value = scoped ? navValue : int256(0);
        if (scoped && balanceToken != address(0)) {
            nav.value += int256(IERC20(balanceToken).balanceOf(account) * balanceScale);
        }
        nav.quoteAsset = INavCalculator.Asset({asset: quoteAsset, symbol: "USD", decimals: 8});
        nav.timestamp = uint64(block.timestamp);
        nav.sequencerDown = sequencerDown;
        nav.quoteAssetStale = quoteAssetStale;
        nav.quoteAssetIrregular = quoteAssetIrregular;
        nav.stalePriceAssets = _toAssets(_staleAssets);
        nav.irregularPriceAssets = _toAssets(_irregularAssets);
        nav.monitorsUnhealthyPriceAssets = _toAssets(_monitorsUnhealthyAssets);
    }

    function isAssetRegistered(address asset) external view returns (bool) {
        return _registered[asset];
    }

    function getRegisteredAsset(address asset)
        external
        view
        returns (INavCalculator.Asset memory assetInfo, bool found)
    {
        found = _registered[asset];
        if (found) {
            assetInfo = INavCalculator.Asset({asset: asset, symbol: "MOCK", decimals: _registeredDecimals[asset]});
        }
    }

    function getPriceData(address underlyingAsset) external view returns (INavCalculator.PriceFeedData memory data) {
        if (!_registered[underlyingAsset]) revert AssetNotFound();

        FeedConfig memory feed = _feeds[underlyingAsset];
        if (!feed.set) revert PriceFeedNotSet();
        if (feed.reverts) revert PriceFeedNotSet();

        data.priceFeed = address(uint160(uint256(keccak256(abi.encode(underlyingAsset)))));
        data.price = feed.price;
        data.decimals = feed.decimals;
        data.stale = feed.stale;
        data.sequencerDown = feed.sequencerDown;
        data.irregular = feed.irregular;
        data.healthyFeedCount = 1;
        data.monitorFeedCount = 1;
        data.updatedAt = block.timestamp;
    }

    function usdDecimals() external pure returns (uint8) {
        return 8;
    }

    function _toAssets(address[] storage src) private view returns (INavCalculator.Asset[] memory out) {
        out = new INavCalculator.Asset[](src.length);
        for (uint256 i; i < src.length; i++) {
            out[i] = INavCalculator.Asset({asset: src[i], symbol: "X", decimals: 18});
        }
    }
}

/// @notice A NAV calculator that reports the wrong USD scale, to exercise `setNavCalculator`'s guard
contract MockWrongScaleNavCalculator {
    function usdDecimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice A future NAV calculator that has APPENDED a tenth field to the `NAV` struct.
/// @dev Models upstream's actual drift convention — `irregularPriceAssets`, `quoteAssetIrregular` and
///      `monitorsUnhealthyPriceAssets` were all appended this way. The point of this mock is that the
///      appended field is a HEALTH SIGNAL that is screaming while every field the nine-field mirror
///      knows about reads perfectly healthy, which is precisely the scenario in which silent
///      append-drift would cost money.
contract MockNavCalculatorV10 {
    struct AssetX {
        address asset;
        string symbol;
        uint8 decimals;
    }

    struct NAV10 {
        int256 value;
        AssetX quoteAsset;
        uint64 timestamp;
        AssetX[] stalePriceAssets;
        bool sequencerDown;
        bool quoteAssetStale;
        AssetX[] irregularPriceAssets;
        bool quoteAssetIrregular;
        AssetX[] monitorsUnhealthyPriceAssets;
        AssetX[] newlyAppendedTroubleAssets;
    }

    int256 public navValue;

    constructor(int256 value) {
        navValue = value;
    }

    function getAccountNav(address, address quoteAsset) external view returns (NAV10 memory nav) {
        nav.value = navValue;
        nav.quoteAsset = AssetX({asset: quoteAsset, symbol: "USD", decimals: 8});
        nav.timestamp = uint64(block.timestamp);
        // Everything the nine-field mirror gates on is healthy...
        nav.stalePriceAssets = new AssetX[](0);
        nav.irregularPriceAssets = new AssetX[](0);
        nav.monitorsUnhealthyPriceAssets = new AssetX[](0);
        // ...while the signal it cannot see reports three troubled assets.
        nav.newlyAppendedTroubleAssets = new AssetX[](3);
    }

    function usdDecimals() external pure returns (uint8) {
        return 8;
    }
}
