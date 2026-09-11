// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {DeployUniswapV3PositionVault} from "../script/DeployUniswapV3PositionVault.s.sol";

/// @title  DeployReader
/// @author KPK
/// @notice Exposes the deploy script's configuration reader so its bounds can be tested directly.
contract DeployReader is DeployUniswapV3PositionVault {
    function readBounded(string memory json, string memory key, string memory field, uint256 max)
        external
        pure
        returns (uint256)
    {
        return _readBounded(json, key, field, max);
    }
}

/// @title  UniswapV3PositionVaultDeployTest
/// @author KPK
/// @notice Covers the deploy script's handling of its own configuration file.
/// @dev    Needs no fork: the reader is pure and is fed JSON inline, so a bad configuration can be
///         exercised without putting one in the file the script actually ships with.
contract UniswapV3PositionVaultDeployTest is Test {
    DeployReader internal reader;

    function setUp() public {
        reader = new DeployReader();
    }

    function test_readBounded_acceptsAValueThatFitsItsDestination() public view {
        assertEq(reader.readBounded('{"v":{"fee":500}}', ".v", ".fee", type(uint24).max), 500, "a real fee reads back");
    }

    function test_readBounded_refusesAValueThatWouldTruncate() public {
        // A narrowing cast keeps the low bits, so this fee would have become 500 and deployed
        // against a real pool that nobody chose. The initializer cannot catch it, because the value
        // it validates is the truncated one.
        uint256 oversized = uint256(type(uint24).max) + 1 + 500;

        vm.expectRevert(bytes("config value out of range:.fee"));
        reader.readBounded(string.concat('{"v":{"fee":', vm.toString(oversized), "}}"), ".v", ".fee", type(uint24).max);
    }

    function test_readBounded_refusesAnOversizedTwapWindow() public {
        uint256 oversized = uint256(type(uint32).max) + 1 + 600;

        vm.expectRevert(bytes("config value out of range:.twapPeriod"));
        reader.readBounded(
            string.concat('{"v":{"twapPeriod":', vm.toString(oversized), "}}"), ".v", ".twapPeriod", type(uint32).max
        );
    }
}
