// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title  INavCalculator
/// @author KPK
/// @notice Minimal consumer-side mirror of karpatkey's `NAVCalculator`, the on-chain net-asset-value
///         oracle from https://github.com/karpatkey/onchain-accounting.
/// @dev    MIRRORED SOURCE — `src/nav/INAVCalculator.sol` @ commit
///         `d290a0427a81a84bf348a8f5e8b0aa8c38890b22` (2026-08-28). The accounting repo is not a
///         submodule here, so this file is maintained by hand and only declares the surface
///         `KpkSharesNav` actually calls.
///
///         STRUCT FIELD ORDER IS ABI-LOAD-BEARING. `NAV` is decoded from the live proxy's return
///         data, so the field list below must match the deployed contract exactly. Upstream appends
///         new fields rather than inserting them (see `irregularPriceAssets` onward), which means a
///         drifted mirror makes `abi.decode` REVERT rather than silently return wrong numbers — the
///         failure is loud and fail-closed, but it halts pricing until this file is updated.
///         `KpkSharesNav.t.sol`'s fork test decodes against the live proxy to catch exactly that.
///
///         Deployed proxy (same address on every supported chain, redeployed 2026-08-18):
///         `0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214`. The superseded proxy
///         `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` still answers but is abandoned in place and
///         will drift from the funds' true NAV — never point a fund at it.
///
///         There is NO stored NAV and no push mechanism: `getAccountNav` performs a full balance-
///         adapter scan inside a `view` call. It is therefore EXPENSIVE and can revert when gas is
///         starved. `NAV.timestamp` is merely the `block.timestamp` of the caller's own read, NOT an
///         oracle update time, so no timestamp-based freshness check against it is meaningful —
///         freshness lives entirely in the health flags.
interface INavCalculator {
    /// @notice Metadata for an asset registered with the NAV calculator.
    /// @param asset The token address (`address(0)` denotes the USD unit of account).
    /// @param symbol The asset's symbol.
    /// @param decimals The asset's decimals (8 for the USD pseudo-asset).
    struct Asset {
        address asset;
        string symbol;
        uint8 decimals;
    }

    /// @notice A net-asset-value snapshot for one account, plus the health of the prices behind it.
    /// @param value The account's NAV. Denominated in USD with 8 decimals when `quoteAsset` was
    ///        requested as `address(0)`, otherwise in the quote asset's own decimals. SIGNED — it
    ///        can be negative when an account's debt exceeds its holdings.
    /// @param quoteAsset The unit of account the value is expressed in.
    /// @param timestamp The `block.timestamp` of this read. NOT an oracle update time.
    /// @param stalePriceAssets Assets whose prices were stale, scoped to those the account's
    ///        positions actually touch — an unrelated stale registry asset does not appear here.
    /// @param sequencerDown True if the L2 sequencer is down or within its grace period.
    /// @param quoteAssetStale True if the quote asset's own feed was stale. WARNING: when this is
    ///        true, `value` silently falls back to USD 8-decimals even though `quoteAsset` is
    ///        non-zero. `KpkSharesNav` sidesteps this entirely by only ever quoting in USD.
    /// @param irregularPriceAssets Assets whose primary feed diverged from its monitors beyond
    ///        tolerance (a manipulation/depeg signal, not a validity verdict).
    /// @param quoteAssetIrregular The `irregularPriceAssets` counterpart for the quote asset.
    /// @param monitorsUnhealthyPriceAssets Assets that have monitor feeds configured but where none
    ///        was readable, so the divergence check silently did not run. `divergenceBps` being 0
    ///        for these means "never computed", not "prices agreed".
    struct NAV {
        int256 value;
        Asset quoteAsset;
        uint64 timestamp;
        Asset[] stalePriceAssets;
        bool sequencerDown;
        bool quoteAssetStale;
        Asset[] irregularPriceAssets;
        bool quoteAssetIrregular;
        Asset[] monitorsUnhealthyPriceAssets;
    }

    /// @notice Price-feed data for a single asset.
    /// @param priceFeed The primary feed address.
    /// @param priceType The feed family. Declared `uint8` here rather than importing upstream's
    ///        `IPrices.PriceType` enum: `uint8` is the ABI-canonical encoding of an enum, so this
    ///        decodes identically without vendoring another interface.
    /// @param price USD per whole unit of the asset, scaled by `10 ** decimals`. Zero when stale.
    /// @param decimals The decimals of `price` itself. READ THIS — do not assume 8.
    /// @param chainlinkHeartbeat The configured heartbeat of the reported feed.
    /// @param updatedAt The reported feed's last push time.
    /// @param stale The AUTHORITATIVE staleness verdict. Upstream is explicit that consumers MUST
    ///        gate on this and must never recompute freshness from `(updatedAt, chainlinkHeartbeat)`,
    ///        which describe only one leg's push freshness and can read fresh while this is true.
    /// @param sequencerDown True if the L2 sequencer is down or within its grace period.
    /// @param healthyFeedCount Number of readable primary feeds.
    /// @param irregular True if the primary diverged from its monitors beyond tolerance.
    /// @param divergenceBps The measured divergence in basis points.
    /// @param monitorFeedCount Number of monitor feeds consulted.
    struct PriceFeedData {
        address priceFeed;
        uint8 priceType;
        int256 price;
        uint8 decimals;
        uint256 chainlinkHeartbeat;
        uint256 updatedAt;
        bool stale;
        bool sequencerDown;
        uint256 healthyFeedCount;
        bool irregular;
        uint256 divergenceBps;
        uint256 monitorFeedCount;
    }

    /// @notice Computes an account's net asset value across every registered balance adapter.
    /// @dev    A full adapter scan. Expensive, and can revert (`AdapterGasExhausted` /
    ///         `InstanceGasExhausted`) when starved of gas — which for a consumer is a fail-closed
    ///         halt rather than a wrong answer.
    /// @param  account The address to value (for a fund, its portfolio Safe).
    /// @param  quoteAsset The unit of account; `address(0)` for USD with 8 decimals.
    /// @return nav The valuation and the health of every price behind it.
    function getAccountNav(address account, address quoteAsset) external view returns (NAV memory nav);

    /// @notice Whether an asset is registered with the NAV calculator.
    /// @dev    A single storage read; never reverts.
    /// @param  asset The asset to check.
    /// @return True if the asset is registered.
    function isAssetRegistered(address asset) external view returns (bool);

    /// @notice Returns an asset's registry metadata without reverting when it is absent.
    /// @dev    Check `found`; do NOT infer absence from a zero `assetInfo.asset`. Prefer this over
    ///         upstream's `getAssetInfo`, which is a fail-closed classifier that REVERTS for
    ///         unclassified assets and so cannot be used as an existence probe.
    /// @param  asset The asset to look up.
    /// @return assetInfo The asset's metadata (zeroed when not found).
    /// @return found True if the asset is registered.
    function getRegisteredAsset(address asset) external view returns (Asset memory assetInfo, bool found);

    /// @notice Returns the primary price plus the monitor-divergence signal for an asset.
    /// @dev    REVERTS if the asset is unregistered or has no feed configured. The divergence-free
    ///         variant is cheaper but leaves `irregular` at its default, which would silently defeat
    ///         a strict health policy — so this fund deliberately pays for the full check.
    /// @param  underlyingAsset The asset to price.
    /// @return priceFeedData The price and its health.
    function getPriceData(address underlyingAsset) external view returns (PriceFeedData memory priceFeedData);

    /// @notice The number of decimals used for USD-denominated values.
    /// @return The USD scale (8).
    function usdDecimals() external view returns (uint8);
}
