// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {Test} from "forge-std/Test.sol";
import {INavCalculator} from "../src/interfaces/INavCalculator.sol";
import {MockNavCalculator, MockNavCalculatorV10} from "./mocks/MockNavCalculator.sol";

/// @title kpkSharesNavDriftTest
/// @notice Pins down how `INavCalculator` behaves when the deployed NAV contract drifts away from
///         this repo's hand-maintained mirror, and provides the alarm that makes the dangerous
///         direction loud.
/// @dev The mirror is maintained by hand because the accounting repo is not a submodule here, so
///      drift is a question of when, not if. These tests exist because the original NatSpec claimed
///      the opposite of what actually happens.
contract kpkSharesNavDriftTest is Test {
    /// @notice An APPENDED field does not make decoding revert — it is silently dropped.
    /// @dev This is the finding that matters. Upstream appends rather than inserts (that is how
    ///      `irregularPriceAssets` and `monitorsUnhealthyPriceAssets` arrived), and Solidity's
    ///      decoder reads this struct's head words and follows their self-describing offsets, so a
    ///      longer encoding decodes cleanly. If the appended field is a new HEALTH SIGNAL, the fund
    ///      keeps pricing and simply never gates on it — the fail-closed guarantee erodes in silence.
    function testAppendedFieldIsSilentlyDropped() public {
        MockNavCalculatorV10 future = new MockNavCalculatorV10(12345);

        INavCalculator.NAV memory nav = INavCalculator(address(future)).getAccountNav(address(this), address(0));

        // Decoding succeeded against a TEN-field encoding...
        assertEq(nav.value, 12345, "value still decodes correctly");
        assertEq(nav.quoteAsset.decimals, 8);

        // ...and every trouble array the mirror knows about reads healthy, even though the appended
        // field is reporting three troubled assets that this fund cannot see.
        assertEq(nav.stalePriceAssets.length, 0);
        assertEq(nav.irregularPriceAssets.length, 0);
        assertEq(nav.monitorsUnhealthyPriceAssets.length, 0);
    }

    /// @notice The length alarm fires on an appended field.
    /// @dev A canonical re-encode of the nine fields we decoded is shorter than the raw response
    ///      whenever the response carried more. This is the check the fork test runs against the
    ///      live proxy, so real upstream drift turns CI red instead of going unnoticed.
    function testLengthAlarmFiresOnAppendedField() public {
        MockNavCalculatorV10 future = new MockNavCalculatorV10(12345);

        (bytes memory raw, bytes memory reencoded) = _probe(address(future));

        assertGt(raw.length, reencoded.length, "alarm must fire: response is longer than nine fields");
    }

    /// @notice The length alarm does NOT fire on a correct nine-field response.
    /// @dev The other direction. An alarm that fires on valid data is worse than no alarm, because
    ///      it gets muted.
    function testLengthAlarmSilentOnMatchingInterface() public {
        MockNavCalculator current = new MockNavCalculator();
        current.setNavValue(12345);

        (bytes memory raw, bytes memory reencoded) = _probe(address(current));

        assertEq(raw.length, reencoded.length, "alarm must stay silent on a matching interface");
    }

    /// @notice Calls `getAccountNav` raw, then re-encodes what we decoded, and returns both.
    /// @param navCalculator The calculator to probe
    /// @return raw The untouched response bytes
    /// @return reencoded A canonical encoding of the nine fields this repo's mirror declares
    function _probe(address navCalculator) internal view returns (bytes memory raw, bytes memory reencoded) {
        (bool ok, bytes memory data) =
            navCalculator.staticcall(abi.encodeCall(INavCalculator.getAccountNav, (address(this), address(0))));
        require(ok, "getAccountNav reverted");

        INavCalculator.NAV memory nav = abi.decode(data, (INavCalculator.NAV));
        return (data, abi.encode(nav));
    }
}
