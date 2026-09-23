// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Mock_HookERC20
/// @notice An ERC-20 that calls an arbitrary target from inside its own transfer, the way ERC-777's
///         `tokensToSend`/`tokensReceived` and ERC-1363 callbacks do.
/// @dev Exists to make transfer-ordering testable. A plain ERC-20 cannot distinguish "state updated
///      before the transfer" from "after", because nothing observes the intermediate moment — so a
///      test using one asserts an end state that is identical either way. This token re-enters at
///      exactly that moment, which is the only place the ordering is observable.
///
///      The repo does not support callback tokens in production; this is a test instrument for
///      proving a guard holds, not an endorsement of listing one.
contract Mock_HookERC20 is ERC20 {
    uint8 internal _decimals;
    address public hookTarget;
    bytes public hookCalldata;
    bool internal _inHook;

    /// @notice Records whether the most recent re-entrant call succeeded
    bool public lastHookSucceeded;

    constructor(string memory symbol, uint8 decimals_) ERC20(symbol, symbol) {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Sets the call this token makes from inside every transfer
    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookCalldata = data;
    }

    /// @dev Fires after balances have moved — the same window an ERC-777 recipient hook occupies.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);

        if (hookTarget != address(0) && !_inHook) {
            _inHook = true;
            (bool ok,) = hookTarget.call(hookCalldata);
            lastHookSucceeded = ok;
            _inHook = false;
        }
    }
}
