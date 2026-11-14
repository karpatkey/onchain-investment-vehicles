// SPDX-License-Identifier: MIT
pragma solidity ^0.8;

/// @title Mock_MalformedPerfFeeModule
/// @notice A performance fee module that answers with the wrong NUMBER OF BYTES.
/// @dev The reverting mock covers the failure everyone thinks of. This covers the one that actually
///      slipped through two rounds of fixes: the call SUCCEEDS and the caller dies decoding the
///      reply. Reachable without malice — an upgraded module that renames or re-signs
///      `calculatePerformanceFee` falls through to a fallback that returns nothing.
///
///      The size must be controlled in assembly. A `fallback(bytes calldata) returns (bytes memory)`
///      would ABI-encode the reply as offset + length + padded data, so asking it for zero bytes
///      still puts 64 on the wire and the short-return case could not be expressed at all.
///
///      Interesting values are not only the short ones: 0 and 8 are too short to be a `uint256`;
///      64 and 1024 are LONGER than needed and must be ACCEPTED, since a fund that halted on a
///      chatty module would have the same bug pointing the other way.
contract Mock_MalformedPerfFeeModule {
    uint256 public returnSize;
    uint256 public fee;

    constructor(uint256 returnSize_, uint256 fee_) {
        returnSize = returnSize_;
        fee = fee_;
    }

    fallback() external {
        uint256 size = returnSize;
        uint256 value = fee;
        assembly {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, add(size, 0x20)))
            // Fresh memory past the free pointer is zero, so anything beyond the first word is
            // well-formed padding rather than noise.
            if iszero(lt(size, 32)) { mstore(ptr, value) }
            return(ptr, size)
        }
    }
}
