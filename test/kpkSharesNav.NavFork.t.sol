// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test, console} from "forge-std/Test.sol";
import {INavCalculator} from "../src/interfaces/INavCalculator.sol";

/// @title kpkSharesNavForkTest
/// @notice Guards `INavCalculator` against drift from the deployed `NAVCalculator`.
/// @dev `src/interfaces/INavCalculator.sol` is a hand-maintained mirror, because the accounting repo
///      is not a submodule here. Its `NAV` struct is decoded from the live proxy's return data, so a
///      field appended upstream makes `abi.decode` REVERT rather than return wrong numbers. That is
///      fail-closed, but it halts a fund's pricing until the mirror is updated — so it is worth
///      finding here rather than in production.
///
///      Skips when `MAINNET_URL` is unset, so it does not break a local run without an RPC. The
///      repo's other fork suites (`KpkOivFactory.t.sol`, `CcipOivDeployer.t.sol`) fail hard in
///      `setUp` in that situation; this one deliberately does not, because it is a drift alarm
///      rather than a test of our own logic.
contract kpkSharesNavForkTest is Test {
    /// @notice karpatkey's NAVCalculator proxy, redeployed 2026-08-18, identical on every chain
    /// @dev The superseded proxy `0x80eD5cc6cEbAe4fEE1eD8687279aa492A50afa8d` still answers but is
    ///      abandoned in place and will drift from the funds' true NAV. Never point a fund at it.
    address internal constant NAV_CALCULATOR = 0x54EaD2A1dB7456cA917675Ea8908ec8A997c6214;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("MAINNET_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        return true;
    }

    /// @notice The mirrored `NAV` struct still decodes against the deployed contract
    function testNavStructStillDecodes() public {
        if (!_fork()) {
            console.log("MAINNET_URL unset - skipping NAV interface drift check");
            return;
        }
        require(NAV_CALCULATOR.code.length > 0, "no code at the configured NAV proxy");

        // Any account works; an empty one returns a zero NAV rather than reverting. What is being
        // asserted is that the return data decodes into our struct at all.
        INavCalculator.NAV memory nav = INavCalculator(NAV_CALCULATOR).getAccountNav(address(this), address(0));

        assertEq(nav.quoteAsset.decimals, 8, "USD quote should carry 8 decimals");
        assertEq(nav.timestamp, uint64(block.timestamp), "timestamp is the read's own block time");
    }

    /// @notice The USD scale this contract's arithmetic assumes still holds
    function testUsdDecimalsIsEight() public {
        if (!_fork()) {
            console.log("MAINNET_URL unset - skipping NAV interface drift check");
            return;
        }
        assertEq(INavCalculator(NAV_CALCULATOR).usdDecimals(), 8);
    }

    /// @notice `isAssetRegistered` and `getRegisteredAsset` still answer without reverting
    function testRegistryProbesDoNotRevert() public {
        if (!_fork()) {
            console.log("MAINNET_URL unset - skipping NAV interface drift check");
            return;
        }

        // An address that cannot be registered: the probes must report absence, not revert.
        address stranger = address(uint160(uint256(keccak256("definitely not a registered asset"))));
        assertFalse(INavCalculator(NAV_CALCULATOR).isAssetRegistered(stranger));

        (, bool found) = INavCalculator(NAV_CALCULATOR).getRegisteredAsset(stranger);
        assertFalse(found, "getRegisteredAsset must report absence via `found`, not revert");
    }
}
