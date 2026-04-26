// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ICoreWriter {
    function sendRawAction(bytes calldata data) external;
}

address constant CORE_WRITER = 0x3333333333333333333333333333333333333333;
