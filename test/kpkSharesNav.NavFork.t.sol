// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test, console} from "forge-std/Test.sol";
import {INavCalculator} from "../src/interfaces/INavCalculator.sol";

/// @title kpkSharesNavForkTest
/// @notice Guards `INavCalculator` against drift from the deployed `NAVCalculator`.
/// @dev `src/interfaces/INavCalculator.sol` is a hand-maintained mirror, because the accounting repo
///      is not a submodule here. A field APPENDED upstream does NOT make `abi.decode` revert — the
///      decoder follows this struct's self-describing offsets and silently drops the extra field
///      (proved in `test/kpkSharesNav.Drift.t.sol`). If that appended field is a new health signal,
///      the fund keeps pricing and never gates on it. So decodability is not the thing to assert:
///      this test compares the ENCODED LENGTH of the live response against a canonical re-encode of
///      the nine fields the mirror declares, which turns real upstream drift into a red CI run.
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

    /// @notice The deployed `NAV` struct still has exactly the nine fields this repo mirrors
    /// @dev Asserting decodability alone would pass even after upstream appended a tenth field, so
    ///      this compares encoded lengths. A longer live response means upstream has appended
    ///      something the health gate in `NavPricingLib` cannot possibly be checking.
    function testNavStructHasNotDrifted() public {
        if (!_fork()) {
            console.log("MAINNET_URL unset - skipping NAV interface drift check");
            return;
        }
        require(NAV_CALCULATOR.code.length > 0, "no code at the configured NAV proxy");

        (bool ok, bytes memory raw) =
            NAV_CALCULATOR.staticcall(abi.encodeCall(INavCalculator.getAccountNav, (address(this), address(0))));
        require(ok, "getAccountNav reverted on the live proxy");

        // Any account works; an empty one returns a zero NAV rather than reverting.
        INavCalculator.NAV memory nav = abi.decode(raw, (INavCalculator.NAV));

        assertEq(nav.quoteAsset.decimals, 8, "USD quote should carry 8 decimals");
        assertEq(nav.timestamp, uint64(block.timestamp), "timestamp is the read's own block time");

        assertEq(
            raw.length,
            abi.encode(nav).length,
            "NAV struct drifted: the live response carries fields src/interfaces/INavCalculator.sol does not declare"
        );
    }

    /// @notice The NAV scan still fits in a sane fraction of a block.
    /// @dev This is a trend alarm, not a correctness test. `getAccountNav` is a full adapter scan
    ///      whose cost grows every time upstream registers a new balance adapter — with no change to
    ///      this repo. It moved ~30% in a single day on 2026-08-28 when a rewards adapter was
    ///      registered, and nothing here noticed. Because the fund is fail-closed, a scan that
    ///      eventually exceeds the block limit does not misprice, it HALTS settlement permanently.
    ///
    ///      Asserted as a fraction of `block.gaslimit` rather than an absolute number, because the
    ///      absolute number is upstream's to move and a hardcoded one would only rot. The account is
    ///      one with no positions, so this is a floor: a real portfolio costs strictly more.
    function testNavScanFitsInABlock() public {
        if (!_fork()) {
            console.log("MAINNET_URL unset - skipping NAV gas headroom check");
            return;
        }

        uint256 before = gasleft();
        (bool ok,) =
            NAV_CALCULATOR.staticcall(abi.encodeCall(INavCalculator.getAccountNav, (address(this), address(0))));
        uint256 used = before - gasleft();
        require(ok, "getAccountNav reverted on the live proxy");

        console.log("getAccountNav gas (empty account):", used);
        console.log("block gas limit:", block.gaslimit);

        assertLt(
            used,
            block.gaslimit / 3,
            "NAV scan exceeds a third of a block for an EMPTY account - settlement headroom is gone"
        );
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
