// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Mock CoreWriter that records all sendRawAction calls for inspection
contract MockCoreWriter {
    struct RawActionCall {
        bytes data;
        address sender;
    }

    RawActionCall[] public calls;

    function sendRawAction(bytes calldata data) external {
        calls.push(RawActionCall({data: data, sender: msg.sender}));
    }

    function callCount() external view returns (uint256) {
        return calls.length;
    }

    function getCallData(uint256 index) external view returns (bytes memory) {
        return calls[index].data;
    }

    function getCallSender(uint256 index) external view returns (address) {
        return calls[index].sender;
    }

    function reset() external {
        delete calls;
    }
}
