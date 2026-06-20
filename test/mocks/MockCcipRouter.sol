// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Client} from "chainlink-brownie-contracts/contracts/src/v0.8/ccip/libraries/Client.sol";

/// @notice Minimal CCIP Router stand-in for unit tests. `ccipSend` records the outbound message and
///         pulls the LINK fee via `transferFrom` (mirroring the real router), but does NOT deliver
///         to the destination — delivery is simulated separately by calling the receiver's
///         `ccipReceive` directly with this mock set as `msg.sender`.
contract MockCcipRouter {
    uint256 public feePerMessage;

    struct Sent {
        uint64 destChainSelector;
        bytes receiver;
        bytes data;
        address feeToken;
        uint256 fee;
    }

    Sent[] public sent;

    function setFee(uint256 fee) external {
        feePerMessage = fee;
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastData() external view returns (bytes memory) {
        return sent[sent.length - 1].data;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        return feePerMessage;
    }

    function ccipSend(uint64 destChainSelector, Client.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32)
    {
        if (message.feeToken != address(0)) {
            IERC20(message.feeToken).transferFrom(msg.sender, address(this), feePerMessage);
        }
        bytes32 messageId = keccak256(abi.encode(destChainSelector, sent.length, message.data));
        sent.push(
            Sent({
                destChainSelector: destChainSelector,
                receiver: message.receiver,
                data: message.data,
                feeToken: message.feeToken,
                fee: feePerMessage
            })
        );
        return messageId;
    }
}
