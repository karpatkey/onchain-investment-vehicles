// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {KpkSharesNav} from "../KpkSharesNav.sol";
import {NavPricingLib} from "../utils/NavPricingLib.sol";

/// @title  KpkSharesNavLens
/// @author kpk
/// @notice Read-only introspection for a `KpkSharesNav` fund: what the share price is right now,
///         whether the fund could actually settle against it, and — when it could not — exactly
///         which signal is stopping it.
///
/// @dev    WHY THIS IS NOT ON THE FUND
///         It was measured, not assumed. `KpkSharesNav` sits at 24,473 bytes against EIP-170's
///         24,576, leaving 103. Adding just the share-price-with-health view took it to 24,773
///         (197 over); adding the NAV status view as well took it to 25,396 (820 over). The cheaper
///         of the two needs ~300 bytes against a 103-byte budget, so neither fits, and freeing that
///         much would mean cutting settlement code to make room for a monitor.
///
///         Putting it here is better than a squeeze anyway: the fund's bytes stay frozen after six
///         review rounds, this contract can be redeployed or extended without touching an audited
///         fund, and having ~24KB of its own means it can return the offending asset ADDRESSES
///         rather than counts.
///
///         WHY IT DELEGATES THE HEALTH VERDICT
///         The `healthy` answer comes from `NavPricingLib`, the same library the settlement path
///         calls. A monitor that re-implemented the gate would eventually disagree with it, and the
///         failure would be silent and in the worst direction: a dashboard reporting healthy while
///         every batch reverts. There is one definition of "can this fund price", in one file.
///
///         WHAT IT IS NOT
///         It has no state, no privileges and no ability to move anything. It is safe to point at a
///         fund it does not know, and safe for anyone to call. It is also NOT cheap: every status
///         read triggers a full NAV adapter scan, so call it off-chain (`eth_call`) rather than
///         from a transaction.
contract KpkSharesNavLens {
    /// @notice Everything worth knowing about a fund's ability to price itself, in one call.
    struct FundStatus {
        /// @notice The fund's configured NAV calculator and the account it values.
        address navCalculator;
        address portfolioSafe;
        /// @notice Share supply, and one whole share in its own units.
        uint256 totalSupply;
        /// @notice Price per share in USD with 8 decimals, or 0 when the fund could not use it.
        uint256 sharePriceUsd;
        /// @notice Whether the fund could settle a batch right now. This is the headline answer.
        bool canSettle;
        /// @notice True when supply is zero, so `sharePriceUsd` is the bootstrap price rather than a
        ///         derived one. A first subscription would mint at exactly this price.
        bool bootstrapping;
        /// @notice False when the NAV calculator did not answer at all. Every NAV field below is
        ///         meaningless when this is false — distinct from "answered, and unhealthy".
        bool answered;
        /// @notice The NAV in USD with 8 decimals, as reported. Negative means debts exceed holdings,
        ///         which halts pricing: there is no honest price for a share of that.
        int256 navUsd;
        uint64 navTimestamp;
        /// @notice The three scalar health flags, straight from the calculator.
        bool sequencerDown;
        bool quoteAssetStale;
        bool quoteAssetIrregular;
        /// @notice The assets actually responsible for a halt, by address.
        address[] stalePriceAssets;
        address[] irregularPriceAssets;
        address[] monitorsUnhealthyPriceAssets;
    }

    /// @notice The share price right now and whether the fund could use it.
    /// @dev The non-reverting counterpart to `KpkSharesNav.getSharePriceUsd`, which is health-gated
    ///      and reverts while the NAV is unhealthy. That is correct for settlement and useless for
    ///      monitoring: the moment you most need to read a fund is the moment it cannot price.
    ///      A zero price is never usable, so `(0, false)` cannot be mistaken for an answer.
    /// @param fund The `KpkSharesNav` proxy to inspect.
    /// @return sharePriceUsd Price per share in USD with 8 decimals, or 0 when unusable.
    /// @return healthy Whether the fund could settle against this price right now.
    function sharePrice(address fund) external view returns (uint256 sharePriceUsd, bool healthy) {
        KpkSharesNav f = KpkSharesNav(fund);

        uint256 supply = f.totalSupply();
        if (supply == 0) return (f.initialSharePrice(), true);

        return NavPricingLib.sharePriceStatus(f.navCalculator(), f.portfolioSafe(), supply, 10 ** f.decimals());
    }

    /// @notice The full picture: the price, the NAV behind it, and every signal behind the verdict.
    /// @dev Answers "why can this fund not price right now" without reverting — which the settlement
    ///      path deliberately cannot do, because it must fail closed.
    /// @param fund The `KpkSharesNav` proxy to inspect.
    /// @return status See `FundStatus`.
    function navStatus(address fund) external view returns (FundStatus memory status) {
        KpkSharesNav f = KpkSharesNav(fund);

        status.navCalculator = f.navCalculator();
        status.portfolioSafe = f.portfolioSafe();
        status.totalSupply = f.totalSupply();

        NavPricingLib.NavStatus memory nav = NavPricingLib.navStatus(status.navCalculator, status.portfolioSafe);

        status.answered = nav.answered;
        status.navUsd = nav.navUsd;
        status.navTimestamp = nav.timestamp;
        status.sequencerDown = nav.sequencerDown;
        status.quoteAssetStale = nav.quoteAssetStale;
        status.quoteAssetIrregular = nav.quoteAssetIrregular;
        status.stalePriceAssets = nav.stalePriceAssets;
        status.irregularPriceAssets = nav.irregularPriceAssets;
        status.monitorsUnhealthyPriceAssets = nav.monitorsUnhealthyPriceAssets;

        if (status.totalSupply == 0) {
            // A fund with no shares prices the next subscription at its bootstrap price, and does so
            // WITHOUT reading the NAV at all. So it can settle even while the calculator is
            // unhealthy — reporting the NAV's condition alongside would be misleading if it were
            // read as the reason this fund can trade.
            status.bootstrapping = true;
            status.sharePriceUsd = f.initialSharePrice();
            status.canSettle = true;
            return status;
        }

        (status.sharePriceUsd, status.canSettle) = NavPricingLib.sharePriceStatus(
            status.navCalculator, status.portfolioSafe, status.totalSupply, 10 ** f.decimals()
        );
    }

    /// @notice Whether one asset is listed on the fund AND currently priceable by its calculator.
    /// @dev Two different questions that both have to be true before a request in that asset can
    ///      settle, and they fail independently: an asset stays listed after its feed goes stale.
    /// @param fund The `KpkSharesNav` proxy to inspect.
    /// @param asset The ERC-20 to check.
    /// @return listedForDeposit Whether subscriptions may be made in this asset.
    /// @return listedForRedeem Whether redemptions may be paid in this asset.
    /// @return priceable Whether the NAV calculator can currently price it.
    function assetStatus(address fund, address asset)
        external
        view
        returns (bool listedForDeposit, bool listedForRedeem, bool priceable)
    {
        KpkSharesNav f = KpkSharesNav(fund);

        KpkSharesNav.ApprovedAsset memory listed = f.getApprovedAsset(asset);
        listedForDeposit = listed.canDeposit;
        listedForRedeem = listed.canRedeem;

        priceable = NavPricingLib.isAssetPriceable(f.navCalculator(), asset);
    }
}
