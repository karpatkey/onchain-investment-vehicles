// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

import {IPerfFeeModule} from "../../src/FeeModules/IPerfFeeModule.sol";

/// @title Mock_RevertingPerfFeeModule
/// @notice A performance fee module that stops answering.
/// @dev Models the realistic failure rather than an exotic one: a module is an independently
///      deployed contract the fund only knows through an interface. It can be a proxy that gets
///      upgraded, can acquire access control, or can simply have an edge case that reverts. The fund
///      must not be brickable by one, so this exists to prove it is not.
contract Mock_RevertingPerfFeeModule is IPerfFeeModule {
    error ModuleIsBroken();

    bool public broken;

    function setBroken(bool value) external {
        broken = value;
    }

    function calculatePerformanceFee(uint256, uint256, uint256, uint256) external view returns (uint256) {
        if (broken) revert ModuleIsBroken();
        return 0;
    }
}
