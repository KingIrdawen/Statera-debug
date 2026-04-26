// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BridgeLib} from "../../src/libraries/BridgeLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreDepositWallet} from "../../src/interfaces/ICoreDepositWallet.sol";
import {CoreActionLib} from "../../src/libraries/CoreActionLib.sol";
import {ICoreWriter, CORE_WRITER} from "../../src/interfaces/ICoreWriter.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";
import {ERC20Mock} from "../integration/ERC20Mock.sol";

contract BridgeLibTest is Test {
    // ═══ HYPE_BRIDGE constant ═══

    function test_hypeBridgeAddress() public pure {
        assertEq(BridgeLib.HYPE_BRIDGE, 0x2222222222222222222222222222222222222222);
    }

    // ═══ buildSystemAddress ═══

    function test_buildSystemAddress_tokenIndex0() public pure {
        address result = BridgeLib.buildSystemAddress(0);
        assertEq(result, address(0x2000000000000000000000000000000000000000));
    }

    function test_buildSystemAddress_tokenIndex1_PURR() public pure {
        address result = BridgeLib.buildSystemAddress(1);
        assertEq(result, address(0x2000000000000000000000000000000000000001));
    }

    function test_buildSystemAddress_tokenIndex150_HYPE() public pure {
        address result = BridgeLib.buildSystemAddress(150);
        // 0x2000...0096 (150 = 0x96)
        assertEq(result, address(uint160(0x2000000000000000000000000000000000000000) + 150));
    }

    function test_buildSystemAddress_maxTokenIndex() public pure {
        address result = BridgeLib.buildSystemAddress(type(uint32).max);
        assertEq(
            result,
            address(uint160(0x2000000000000000000000000000000000000000) + uint160(type(uint32).max))
        );
    }

    // ═══ bridgeHypeEvmToCore ═══

    function test_bridgeHypeEvmToCore_sendsValue() public {
        // Deploy a receiver contract at HYPE_BRIDGE that accepts ETH
        vm.etch(
            BridgeLib.HYPE_BRIDGE,
            hex"00" // minimal code to accept calls
        );
        vm.deal(address(this), 10 ether);

        // We need a wrapper since BridgeLib.bridgeHypeEvmToCore is internal
        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        vm.deal(address(wrapper), 10 ether);

        uint256 balanceBefore = BridgeLib.HYPE_BRIDGE.balance;
        wrapper.bridgeHypeEvmToCore(1 ether);
        uint256 balanceAfter = BridgeLib.HYPE_BRIDGE.balance;

        assertEq(balanceAfter - balanceBefore, 1 ether);
    }

    function test_bridgeHypeEvmToCore_zeroAmount() public {
        vm.etch(BridgeLib.HYPE_BRIDGE, hex"00");
        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        vm.deal(address(wrapper), 1 ether);

        // Zero amount should succeed
        wrapper.bridgeHypeEvmToCore(0);
    }

    // ═══ bridgeTokenEvmToCore ═══

    function test_bridgeTokenEvmToCore_transfersToSystemAddress() public {
        ERC20Mock token = new ERC20Mock("PURR", "PURR", 18);
        BridgeLibWrapper wrapper = new BridgeLibWrapper();

        uint32 tokenIndex = 1;
        address systemAddr = BridgeLib.buildSystemAddress(tokenIndex);

        // Mint tokens to the wrapper
        token.mint(address(wrapper), 1000e18);

        uint256 amount = 500e18;
        uint256 systemBefore = token.balanceOf(systemAddr);
        wrapper.bridgeTokenEvmToCore(address(token), tokenIndex, amount);
        uint256 systemAfter = token.balanceOf(systemAddr);

        assertEq(systemAfter - systemBefore, amount);
        assertEq(token.balanceOf(address(wrapper)), 500e18);
    }

    function test_bridgeTokenEvmToCore_reverts_insufficientBalance() public {
        ERC20Mock token = new ERC20Mock("PURR", "PURR", 18);
        BridgeLibWrapper wrapper = new BridgeLibWrapper();

        // No tokens minted to wrapper
        vm.expectRevert();
        wrapper.bridgeTokenEvmToCore(address(token), 1, 100e18);
    }

    // ═══ bridgeUsdcEvmToCore ═══

    function test_bridgeUsdcEvmToCore_approvesAndDeposits() public {
        ERC20Mock usdc = new ERC20Mock("USDC", "USDC", 6);
        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet(address(usdc));
        BridgeLibWrapper wrapper = new BridgeLibWrapper();

        uint256 amount = 1000e6; // 1000 USDC
        usdc.mint(address(wrapper), amount);

        wrapper.bridgeUsdcEvmToCore(address(usdc), address(depositWallet), amount);

        // Verify deposit wallet received the tokens
        assertEq(depositWallet.totalDeposited(), amount);
        assertEq(usdc.balanceOf(address(wrapper)), 0);
        assertEq(usdc.balanceOf(address(depositWallet)), amount);
    }

    function test_bridgeUsdcEvmToCore_notTransfer() public {
        // Verify USDC bridge uses approve+deposit, NOT transfer
        // The MockCoreDepositWallet.deposit() pulls via transferFrom
        ERC20Mock usdc = new ERC20Mock("USDC", "USDC", 6);
        MockCoreDepositWallet depositWallet = new MockCoreDepositWallet(address(usdc));
        BridgeLibWrapper wrapper = new BridgeLibWrapper();

        uint256 amount = 500e6;
        usdc.mint(address(wrapper), amount);

        // Check allowance is set
        assertEq(usdc.allowance(address(wrapper), address(depositWallet)), 0);
        wrapper.bridgeUsdcEvmToCore(address(usdc), address(depositWallet), amount);

        // deposit() was called (totalDeposited tracks this)
        assertEq(depositWallet.totalDeposited(), amount);
    }

    // ═══ bridgeHypeCoreToEvm ═══

    function test_bridgeHypeCoreToEvm_callsCoreWriter() public {
        MockCoreWriter mockWriter = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(mockWriter).code);

        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        uint64 hypeTokenIndex = 150;
        uint64 weiAmount = 1e8; // 1 HYPE in core wei

        wrapper.bridgeHypeCoreToEvm(hypeTokenIndex, weiAmount);

        // Verify CoreWriter was called with Action 6 (spotSend)
        // Read from the CoreWriter at the system address
        MockCoreWriter writer = MockCoreWriter(CORE_WRITER);
        assertEq(writer.callCount(), 1);

        bytes memory callData = writer.getCallData(0);
        // Verify payload structure: version(1) + actionId(3) + params
        assertEq(uint8(callData[0]), 0x01); // version
        // Action 6 = 0x000006
        assertEq(uint8(callData[1]), 0x00);
        assertEq(uint8(callData[2]), 0x00);
        assertEq(uint8(callData[3]), 0x06);
    }

    function test_bridgeHypeCoreToEvm_sendsToHypeBridge() public {
        MockCoreWriter mockWriter = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(mockWriter).code);

        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        wrapper.bridgeHypeCoreToEvm(150, 5e7); // 0.5 HYPE

        MockCoreWriter writer = MockCoreWriter(CORE_WRITER);
        bytes memory callData = writer.getCallData(0);

        // Decode params after the 4-byte header
        bytes memory params = new bytes(callData.length - 4);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = callData[i + 4];
        }
        (address dest, uint64 tokenIdx, uint64 amount) = abi.decode(params, (address, uint64, uint64));

        assertEq(dest, BridgeLib.HYPE_BRIDGE);
        assertEq(tokenIdx, 150);
        assertEq(amount, 5e7);
    }

    // ═══ bridgeTokenCoreToEvm ═══

    function test_bridgeTokenCoreToEvm_callsCoreWriter() public {
        MockCoreWriter mockWriter = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(mockWriter).code);

        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        uint64 tokenIndex = 1; // PURR
        uint64 weiAmount = 100000; // 1 PURR in core wei (weiDecimals=5)

        wrapper.bridgeTokenCoreToEvm(tokenIndex, weiAmount);

        MockCoreWriter writer = MockCoreWriter(CORE_WRITER);
        assertEq(writer.callCount(), 1);

        bytes memory callData = writer.getCallData(0);
        // Verify Action 6
        assertEq(uint8(callData[0]), 0x01);
        assertEq(uint8(callData[1]), 0x00);
        assertEq(uint8(callData[2]), 0x00);
        assertEq(uint8(callData[3]), 0x06);
    }

    function test_bridgeTokenCoreToEvm_sendsToSystemAddress() public {
        MockCoreWriter mockWriter = new MockCoreWriter();
        vm.etch(CORE_WRITER, address(mockWriter).code);

        BridgeLibWrapper wrapper = new BridgeLibWrapper();
        uint64 tokenIndex = 1;
        uint64 weiAmount = 50000;

        wrapper.bridgeTokenCoreToEvm(tokenIndex, weiAmount);

        MockCoreWriter writer = MockCoreWriter(CORE_WRITER);
        bytes memory callData = writer.getCallData(0);

        // Decode params
        bytes memory params = new bytes(callData.length - 4);
        for (uint256 i = 0; i < params.length; i++) {
            params[i] = callData[i + 4];
        }
        (address dest, uint64 idx, uint64 amount) = abi.decode(params, (address, uint64, uint64));

        assertEq(dest, BridgeLib.buildSystemAddress(uint32(tokenIndex)));
        assertEq(idx, tokenIndex);
        assertEq(amount, weiAmount);
    }

    // ═══ Fuzz ═══

    function testFuzz_buildSystemAddress_neverCollides(uint32 indexA, uint32 indexB) public pure {
        vm.assume(indexA != indexB);
        address addrA = BridgeLib.buildSystemAddress(indexA);
        address addrB = BridgeLib.buildSystemAddress(indexB);
        assertTrue(addrA != addrB);
    }

    function testFuzz_buildSystemAddress_startsWith0x20(uint32 tokenIndex) public pure {
        address result = BridgeLib.buildSystemAddress(tokenIndex);
        // The top byte should be 0x20
        uint160 raw = uint160(result);
        uint8 topByte = uint8(raw >> 152);
        assertEq(topByte, 0x20);
    }
}

contract BridgeLibWrapper {
    function bridgeHypeEvmToCore(uint256 amount) external {
        BridgeLib.bridgeHypeEvmToCore(amount);
    }

    function bridgeTokenEvmToCore(address token, uint32 tokenIndex, uint256 amount) external {
        BridgeLib.bridgeTokenEvmToCore(token, tokenIndex, amount);
    }

    function bridgeUsdcEvmToCore(address usdcToken, address coreDepositWallet, uint256 amount) external {
        BridgeLib.bridgeUsdcEvmToCore(usdcToken, coreDepositWallet, amount);
    }

    function bridgeHypeCoreToEvm(uint64 hypeTokenIndex, uint64 weiAmount) external {
        BridgeLib.bridgeHypeCoreToEvm(hypeTokenIndex, weiAmount);
    }

    function bridgeTokenCoreToEvm(uint64 tokenIndex, uint64 weiAmount) external {
        BridgeLib.bridgeTokenCoreToEvm(tokenIndex, weiAmount);
    }

    receive() external payable {}
}

/// @notice Mock CoreDepositWallet that mimics approve+deposit pattern (not transfer)
contract MockCoreDepositWallet is ICoreDepositWallet {
    address public usdcToken;
    uint256 public totalDeposited;

    constructor(address _usdcToken) {
        usdcToken = _usdcToken;
    }

    function deposit(uint256 amount) external override {
        // Pull tokens via transferFrom (requires prior approval)
        IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;
    }
}
