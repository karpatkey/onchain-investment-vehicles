// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {INavCalculator} from "../interfaces/INavCalculator.sol";

/// @title  NavPricingLib
/// @author kpk
/// @notice Reads and health-gates prices from karpatkey's NAV calculator on behalf of a fund.
/// @dev    THIS IS A LINKED LIBRARY, deployed separately and reached by DELEGATECALL, and it exists
///         in that form for a size reason rather than a design one. `INavCalculator.NAV` carries
///         three dynamic arrays of structs that each contain a `string`, and decoding it generates a
///         lot of code. `KpkSharesNav` prices in six places, and the optimizer — tuned for gas at
///         `optimizer_runs = 2000` — inlines that decoder into every one of them, which pushed the
///         contract past the EIP-170 24,576-byte limit. Holding the decode here keeps one copy, off
///         the fund's own runtime. The NAV repo splits `PriceFeedLib` and `NAVRegistryLib` out of
///         `NAVCalculator` for exactly the same reason.
///
///         The errors below are declared here as well as on `IKpkSharesNav`. A custom error's
///         selector comes from its signature alone, so a revert raised here is indistinguishable to
///         a caller from one raised by the fund itself.
library NavPricingLib {
    using Math for uint256;

    /// @notice The NAV calculator's USD scale, which this library normalizes every price to
    uint8 private constant _USD_DECIMALS = 8;

    /// @notice Error when the NAV snapshot's prices are not healthy enough to price shares
    error NavUnhealthy();

    /// @notice Error when the fund's NAV is zero or negative while shares are outstanding
    error NavNotPositive();

    /// @notice Error when an asset's price is stale, irregular or otherwise unusable
    error AssetPriceUnhealthy();

    /// @notice One pricing snapshot, taken once and reused for every request in a batch
    /// @param sharePriceUsd Price per share in USD (8 decimals)
    /// @param assetPriceUsd Price of one whole unit of the batch asset in USD (8 decimals)
    /// @param assetDecimals The batch asset's decimals
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`
    /// @dev A single snapshot per batch is what stops intra-batch minting and asset movement from
    ///      shifting the price between one request and the next.
    struct Pricing {
        uint256 sharePriceUsd;
        uint256 assetPriceUsd;
        uint8 assetDecimals;
        uint256 shareUnit;
    }

    /// @notice Converts an asset amount to shares at a snapshot price.
    /// @param assetAmount The amount of assets, in the asset's native decimals.
    /// @param p The snapshot to price against.
    /// @return The equivalent shares, in share decimals.
    /// @dev shares = assetAmount * assetPriceUsd * shareUnit / (10^assetDecimals * sharePriceUsd).
    ///      Floors, so rounding never favours the depositor over the existing holders.
    function assetsToShares(uint256 assetAmount, Pricing memory p) internal pure returns (uint256) {
        if (assetAmount == 0) return 0;
        return assetAmount.mulDiv(
            p.assetPriceUsd * p.shareUnit, (10 ** p.assetDecimals) * p.sharePriceUsd, Math.Rounding.Floor
        );
    }

    /// @notice Converts a share amount to assets at a snapshot price.
    /// @param shares The amount of shares, in share decimals.
    /// @param p The snapshot to price against.
    /// @return The equivalent assets, in the asset's native decimals.
    /// @dev assets = shares * sharePriceUsd * 10^assetDecimals / (shareUnit * assetPriceUsd).
    ///      Floors, so rounding never favours the redeemer over the remaining holders.
    function sharesToAssets(uint256 shares, Pricing memory p) internal pure returns (uint256) {
        if (shares == 0) return 0;
        return
            shares.mulDiv(p.sharePriceUsd * (10 ** p.assetDecimals), p.shareUnit * p.assetPriceUsd, Math.Rounding.Floor);
    }

    /// @notice Divides an already-read NAV by a share supply.
    /// @param navValue The NAV in USD with 8 decimals, from an earlier health-gated read.
    /// @param sharesSupply The supply to divide by.
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`.
    /// @return The price per share in USD with 8 decimals, or 0 if it cannot be formed.
    /// @dev Exists so a caller can re-derive the price after minting fee shares WITHOUT a second
    ///      adapter scan. Minting fees changes the supply but not the NAV, so the correct settlement
    ///      price is simply the same NAV over the new supply.
    function sharePriceFrom(int256 navValue, uint256 sharesSupply, uint256 shareUnit) internal pure returns (uint256) {
        if (navValue <= 0 || sharesSupply == 0) return 0;
        return uint256(navValue).mulDiv(shareUnit, sharesSupply, Math.Rounding.Floor);
    }

    /// @notice Derives a fund's price per share from its NAV and its share supply.
    /// @param navCalculator The NAV calculator to read from.
    /// @param account The account holding the fund's assets.
    /// @param sharesSupply The fund's share supply; must be non-zero.
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`.
    /// @return price The price per share in USD with 8 decimals.
    /// @return navValue The NAV the price was derived from, in USD with 8 decimals.
    /// @dev Reverts rather than returning a degraded answer: a caller must not be able to mint or
    ///      burn against prices the NAV itself reports as untrustworthy.
    function sharePriceUsd(address navCalculator, address account, uint256 sharesSupply, uint256 shareUnit)
        external
        view
        returns (uint256 price, int256 navValue)
    {
        return _navSharePrice(navCalculator, account, sharesSupply, shareUnit);
    }

    /// @notice A non-reverting view of the NAV and every signal behind the health decision.
    /// @dev Deliberately parallel to the gate in `_navSharePrice`, and deliberately unable to revert
    ///      where that one does. The settlement path must fail closed; a monitor must not, because
    ///      "the fund cannot price right now" is precisely the state an operator needs to be able to
    ///      READ. A probe that reverted in exactly that state would be useless for the job.
    struct NavStatus {
        /// @notice False when the calculator did not answer at all — a revert, or a reply too short
        ///         to decode. Distinct from "answered, and the answer is unhealthy": every other
        ///         field is meaningless when this is false.
        bool answered;
        /// @notice True when the fund could price against this NAV right now. Combines the health
        ///         flags with the positive-value requirement, because both halt settlement.
        bool healthy;
        /// @notice The NAV in USD with 8 decimals, as reported. Negative means debts exceed holdings.
        int256 navUsd;
        /// @notice The calculator's own read timestamp.
        uint64 timestamp;
        bool sequencerDown;
        bool quoteAssetStale;
        bool quoteAssetIrregular;
        /// @notice The assets actually responsible, not just a count — "which feed is stale" is the
        ///         question an operator has at 3am. Addresses only: the calculator's `Asset` struct
        ///         also carries a `string symbol`, and dragging string encoding through here would
        ///         cost far more than it tells anyone.
        address[] stalePriceAssets;
        address[] irregularPriceAssets;
        address[] monitorsUnhealthyPriceAssets;
    }

    /// @notice Probes the NAV without reverting.
    /// @param navCalculator The NAV calculator to read from.
    /// @param account The account holding the fund's assets.
    /// @return status Every signal behind the health decision; see `NavStatus`.
    function navStatus(address navCalculator, address account) external view returns (NavStatus memory status) {
        return _navStatus(navCalculator, account);
    }

    /// @notice The share price the fund would use right now, and whether it could use it.
    /// @dev Returns `(0, false)` rather than reverting when the NAV is unhealthy, unreachable or
    ///      non-positive. A zero price is never a usable price, so the caller cannot mistake the
    ///      failure case for an answer.
    /// @param navCalculator The NAV calculator to read from.
    /// @param account The account holding the fund's assets.
    /// @param sharesSupply The fund's share supply; must be non-zero.
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`.
    function sharePriceStatus(address navCalculator, address account, uint256 sharesSupply, uint256 shareUnit)
        external
        view
        returns (uint256 price, bool healthy)
    {
        if (sharesSupply == 0) return (0, false);

        NavStatus memory status = _navStatus(navCalculator, account);
        if (!status.healthy) return (0, false);

        price = uint256(status.navUsd).mulDiv(shareUnit, sharesSupply, Math.Rounding.Floor);
        healthy = price != 0;
        if (!healthy) price = 0;
    }

    /// @dev A LOW-LEVEL staticcall, not a high-level one, for the same reason the fund's fee-module
    ///      call is low-level: a high-level call to a codeless address reverts on the `extcodesize`
    ///      probe before the call, and a reply too short to decode reverts after it — both in THIS
    ///      frame, where no `try/catch` can absorb them. Since the whole point of this function is
    ///      not to revert, it has to make no assumption about the reply.
    function _navStatus(address navCalculator, address account) private view returns (NavStatus memory status) {
        (bool ok, bytes memory ret) =
            navCalculator.staticcall(abi.encodeCall(INavCalculator.getAccountNav, (account, address(0))));

        // The NAV struct's fixed head is nine words; anything shorter cannot be one.
        if (!ok || ret.length < 288) return status;

        INavCalculator.NAV memory nav = abi.decode(ret, (INavCalculator.NAV));

        status.answered = true;
        status.navUsd = nav.value;
        status.timestamp = nav.timestamp;
        status.sequencerDown = nav.sequencerDown;
        status.quoteAssetStale = nav.quoteAssetStale;
        status.quoteAssetIrregular = nav.quoteAssetIrregular;
        status.stalePriceAssets = _addresses(nav.stalePriceAssets);
        status.irregularPriceAssets = _addresses(nav.irregularPriceAssets);
        status.monitorsUnhealthyPriceAssets = _addresses(nav.monitorsUnhealthyPriceAssets);

        status.healthy = nav.value > 0 && !nav.sequencerDown && !nav.quoteAssetStale && !nav.quoteAssetIrregular
            && nav.stalePriceAssets.length == 0 && nav.irregularPriceAssets.length == 0
            && nav.monitorsUnhealthyPriceAssets.length == 0;
    }

    /// @dev Strips an `Asset[]` down to its addresses, dropping the symbol strings.
    function _addresses(INavCalculator.Asset[] memory assets) private pure returns (address[] memory out) {
        out = new address[](assets.length);
        for (uint256 i; i < assets.length; i++) {
            out[i] = assets[i].asset;
        }
    }

    /// @notice Reads the NAV, gates its health, and divides it by the share supply.
    /// @param navCalculator The NAV calculator to read from.
    /// @param account The account holding the fund's assets.
    /// @param sharesSupply The fund's share supply; must be non-zero.
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`.
    /// @return price The price per share in USD with 8 decimals.
    /// @return navValue The NAV the price was derived from.
    function _navSharePrice(address navCalculator, address account, uint256 sharesSupply, uint256 shareUnit)
        private
        view
        returns (uint256 price, int256 navValue)
    {
        INavCalculator.NAV memory nav = INavCalculator(navCalculator).getAccountNav(account, address(0));

        // Strictest available policy. The stale and irregular arrays are scoped to the assets this
        // account's own positions touch, so unrelated trouble elsewhere in the NAV registry does not
        // halt this fund. `monitorsUnhealthyPriceAssets` means the divergence check could not run at
        // all — a `divergenceBps` of 0 there means "never computed", not "prices agreed" — so it is
        // treated as unproven rather than as healthy.
        if (
            nav.sequencerDown || nav.quoteAssetStale || nav.quoteAssetIrregular || nav.stalePriceAssets.length != 0
                || nav.irregularPriceAssets.length != 0 || nav.monitorsUnhealthyPriceAssets.length != 0
        ) {
            revert NavUnhealthy();
        }

        // Gate the sign BEFORE casting to unsigned: a negative NAV means the fund's debts exceed its
        // holdings, and there is no honest price for a share of that.
        if (nav.value <= 0) revert NavNotPositive();

        navValue = nav.value;
        price = uint256(nav.value).mulDiv(shareUnit, sharesSupply, Math.Rounding.Floor);
    }

    /// @notice Reads both halves of a pricing snapshot in a single call.
    /// @param navCalculator The NAV calculator to read from.
    /// @param account The account holding the fund's assets.
    /// @param asset The asset the batch or deposit is denominated in.
    /// @param sharesSupply The fund's current share supply.
    /// @param shareUnit One whole share, i.e. `10 ** shareDecimals`.
    /// @param bootstrapPrice The price per share to use while no shares exist.
    /// @return sharePrice The price per share in USD with 8 decimals.
    /// @return assetPrice The asset's price in USD with 8 decimals.
    /// @return navValue The NAV the share price came from, or 0 on the bootstrap path.
    /// @dev Combined into one entry point purely to keep the caller's code small: each library
    ///      boundary costs the calling contract an encode/decode site, and this contract is against
    ///      the EIP-170 limit. While no shares exist the NAV is not read at all — the price is the
    ///      bootstrap price by definition, so the scan would be pure cost.
    function snapshot(
        address navCalculator,
        address account,
        address asset,
        uint256 sharesSupply,
        uint256 shareUnit,
        uint256 bootstrapPrice
    ) external view returns (uint256 sharePrice, uint256 assetPrice, int256 navValue) {
        assetPrice = _assetPrice(navCalculator, asset);
        if (sharesSupply == 0) return (bootstrapPrice, assetPrice, 0);
        (sharePrice, navValue) = _navSharePrice(navCalculator, account, sharesSupply, shareUnit);
    }

    /// @notice Reads one asset's USD price, normalized to 8 decimals.
    /// @param navCalculator The NAV calculator to read from.
    /// @param asset The asset to price.
    /// @return The price of one whole unit of the asset in USD with 8 decimals.
    function assetPriceUsd(address navCalculator, address asset) external view returns (uint256) {
        return _assetPrice(navCalculator, asset);
    }

    /// @notice Whether the NAV calculator can currently produce a usable price for an asset.
    /// @param navCalculator The NAV calculator to read from.
    /// @param asset The asset to check.
    /// @return True if the asset is priceable right now.
    /// @dev Used when listing an asset. `getPriceData` reverts for an unregistered asset or one with
    ///      no feed configured; both mean the same thing here as an unhealthy price, so the revert is
    ///      folded into a false rather than propagated.
    function isAssetPriceable(address navCalculator, address asset) external view returns (bool) {
        try INavCalculator(navCalculator).getPriceData(asset) returns (INavCalculator.PriceFeedData memory data) {
            return _normalize(data) != 0;
        } catch {
            return false;
        }
    }

    /// @notice Reads and health-gates one asset's USD price, normalized to 8 decimals.
    /// @param navCalculator The NAV calculator to read from.
    /// @param asset The asset to price.
    /// @return The price of one whole unit of the asset in USD with 8 decimals.
    /// @dev Uses the divergence-checking read deliberately. The cheaper `getPriceDataNoDivergence`
    ///      leaves `irregular` at its default, which would quietly turn the strict health policy
    ///      into a no-op on this leg.
    function _assetPrice(address navCalculator, address asset) private view returns (uint256) {
        INavCalculator.PriceFeedData memory data = INavCalculator(navCalculator).getPriceData(asset);
        uint256 price = _normalize(data);
        if (price == 0) revert AssetPriceUnhealthy();
        return price;
    }

    /// @notice Health-gates a price feed reading and rescales it to 8 decimals.
    /// @param data The reading to check.
    /// @return The price with 8 decimals, or 0 if it is unusable.
    /// @dev `stale` is the NAV calculator's authoritative verdict — upstream is explicit that
    ///      consumers must gate on it and must never recompute freshness from `updatedAt` and
    ///      `chainlinkHeartbeat`, which can read fresh while `stale` is true. Feed decimals are read
    ///      from the reading rather than assumed, because the NAV reports each feed's own scale.
    ///
    ///      ACCEPTED LIMITATION — down-scaling a feed with more than 8 decimals FLOORS, so the
    ///      relative error is bounded by `1 / price8` and grows without bound as the price falls.
    ///      It is also asymmetric: `sharesToAssets` divides by this price, so an understated price
    ///      makes the fund pay out MORE tokens than the shares are worth. Immaterial above roughly
    ///      $0.0001 per unit (and exactly zero for the 8-decimal feeds Chainlink USD pairs use,
    ///      where this branch is a no-op), but it makes sub-cent assets priced by high-decimal feeds
    ///      a listing-policy question rather than a code one. Do not list one without checking that
    ///      `price8` is large enough that a one-unit truncation is negligible against the fee.
    function _normalize(INavCalculator.PriceFeedData memory data) private pure returns (uint256) {
        if (data.stale || data.sequencerDown || data.irregular || data.price <= 0) return 0;

        uint256 price = uint256(data.price);
        if (data.decimals == _USD_DECIMALS) return price;
        if (data.decimals > _USD_DECIMALS) return price / (10 ** (data.decimals - _USD_DECIMALS));
        return price * (10 ** (_USD_DECIMALS - data.decimals));
    }
}
