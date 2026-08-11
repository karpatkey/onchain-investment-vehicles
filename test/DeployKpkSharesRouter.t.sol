// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {DeployKpkSharesRouter} from "script/DeployKpkSharesRouter.s.sol";
import {IKpkSharesRouter} from "src/periphery/IKpkSharesRouter.sol";

/// @dev Exposes the deploy script's internal config readers so the JSON can be validated in CI without
///      an RPC endpoint. The script's `run` path needs mainnet state; its parsing does not.
contract DeployKpkSharesRouterHarness is DeployKpkSharesRouter {
    function findRouterIndex(string memory json, string memory fundName) external view returns (uint256) {
        return _findRouterIndex(json, fundName);
    }

    function assetCount(string memory json, string memory base) external view returns (uint256) {
        return _assetCount(json, base);
    }

    function readAssetConfig(string memory json, string memory assetPath)
        external
        view
        returns (IKpkSharesRouter.AssetConfig memory)
    {
        return _readAssetConfig(json, assetPath);
    }
}

/// @notice Guards `script/routers.json` against drift: a malformed or renamed field would otherwise only
///         surface at deploy time, against a live fund.
contract DeployKpkSharesRouterTest is Test {
    DeployKpkSharesRouterHarness internal harness;
    string internal json;

    function setUp() public {
        harness = new DeployKpkSharesRouterHarness();
        json = vm.readFile("script/routers.json");
    }

    function test_routersJson_locatesConfiguredFund() public view {
        assertEq(harness.findRouterIndex(json, "kUSD"), 0, "kUSD must be present");
    }

    function test_routersJson_revertsOnUnknownFund() public {
        vm.expectRevert();
        harness.findRouterIndex(json, "kNOPE");
    }

    function test_routersJson_parsesEveryAssetConfig() public view {
        uint256 count = harness.assetCount(json, ".mainnet.chain.routers[0]");
        assertEq(count, 2, "kUSD trades USDC and USDT");

        for (uint256 i = 0; i < count; i++) {
            string memory path = string.concat(".mainnet.chain.routers[0].assets[", vm.toString(i), "]");
            IKpkSharesRouter.AssetConfig memory config = harness.readAssetConfig(json, path);

            // Mirror the on-chain validation in `setAssetConfig`, so a config that would be rejected by
            // the router fails here instead of in a Safe transaction.
            assertTrue(config.subscribeEnabled || config.redeemEnabled, "asset must do something");
            assertGt(config.maxNavTtl, 0, "maxNavTtl must bound the quote lifetime");
            assertGt(config.maxDeviationBps, 0, "maxDeviationBps must be set");
            assertGt(config.priceFloor, 0, "priceFloor must be a real absolute bound");
            assertGe(config.priceCeil, config.priceFloor, "priceCeil must not invert");

            if (config.subscribeEnabled) {
                assertGt(config.maxAssetsInPerTx, 0, "per-tx subscription cap required");
                assertGt(config.maxSharesMintedPerDay, 0, "daily mint budget required");
            }
            if (config.redeemEnabled) {
                assertGt(config.maxSharesInPerTx, 0, "per-tx redemption cap required");
                assertGt(config.maxAssetsOutPerDay, 0, "daily payout budget required");
            }

            // The deviation band must be tighter than the fund's own 30% guard, or it adds nothing.
            assertLt(config.maxDeviationBps, 3000, "router band must be tighter than kpkShares' 3000 bps");
        }
    }

    function test_routersJson_pricesAreEightDecimalScale() public view {
        IKpkSharesRouter.AssetConfig memory config =
            harness.readAssetConfig(json, ".mainnet.chain.routers[0].assets[0]");

        // Sanity-check the scale: a USD share price near $1 is ~1e8. Catches a floor/ceil written in
        // WAD by mistake, which would make the absolute bounds vacuous.
        assertGe(config.priceFloor, 1e7, "floor looks too small for 8-decimal USD");
        assertLe(config.priceCeil, 1e10, "ceil looks too large for 8-decimal USD");
    }
}
