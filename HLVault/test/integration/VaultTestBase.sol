// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";
import {VaultFactory} from "../../src/core/VaultFactory.sol";
import {MockPrecompile} from "../mocks/MockPrecompile.sol";
import {MockCoreWriter} from "../mocks/MockCoreWriter.sol";
import {ERC20Mock} from "./ERC20Mock.sol";

abstract contract VaultTestBase is Test {
    RebalancingVault public vault;
    VaultFactory public factory;
    MockPrecompile public mockPrecompile;
    MockCoreWriter public mockCoreWriter;
    ERC20Mock public counterpartToken;

    address public owner = address(0xA);
    address public keeper = address(0xB);
    address public alice = address(0xC);
    address public bob = address(0xD);

    // Token config: PURR as counterpart
    uint32 constant PURR_TOKEN_INDEX = 1;
    uint32 constant PURR_SPOT_MARKET_INDEX = 0;
    uint32 constant HYPE_TOKEN_INDEX = 150;
    uint32 constant HYPE_SPOT_MARKET_INDEX = 107;
    uint32 constant USDC_TOKEN_INDEX = 0;
    uint8 constant PURR_SZ_DECIMALS = 0;
    uint8 constant PURR_WEI_DECIMALS = 5;
    uint8 constant PURR_EVM_DECIMALS = 18;
    uint256 constant MAX_DEPOSIT = 1000 ether;

    // Prices (rawPrice format from precompile)
    // HYPE: $25, szDecimals=2 -> rawPrice = 25 * 10^(8-2) = 25000000
    uint64 constant HYPE_RAW_PRICE = 25000000;
    // PURR: $0.001, szDecimals=0 -> rawPrice = 0.001 * 10^(8-0) = 100000
    uint64 constant PURR_RAW_PRICE = 100000;

    function setUp() public virtual {
        // Deploy mocks
        mockPrecompile = new MockPrecompile();
        mockCoreWriter = new MockCoreWriter();
        counterpartToken = new ERC20Mock("PURR", "PURR", 18);

        // Etch mocks to system addresses
        _etchPrecompiles();
        vm.etch(0x3333333333333333333333333333333333333333, address(mockCoreWriter).code);

        // We need to copy storage too for the CoreWriter mock
        // Simpler: just etch the mock and accept sendRawAction calls won't revert

        // Set mock prices
        _setDefaultPrices();

        // Deploy factory and vault
        vm.startPrank(owner);
        RebalancingVault impl = new RebalancingVault();
        factory = new VaultFactory(address(impl), keeper);

        address vaultAddr = factory.createVault(
            address(counterpartToken),
            PURR_TOKEN_INDEX,
            PURR_SPOT_MARKET_INDEX,
            HYPE_TOKEN_INDEX,
            HYPE_SPOT_MARKET_INDEX,
            USDC_TOKEN_INDEX,
            PURR_SZ_DECIMALS,
            PURR_WEI_DECIMALS,
            PURR_EVM_DECIMALS,
            MAX_DEPOSIT,
            "HLVault HYPE-PURR",
            "hlPURR"
        );
        vault = RebalancingVault(payable(vaultAddr));
        vm.stopPrank();

        // Fund test accounts
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _etchPrecompiles() internal {
        // We etch the MockPrecompile to each address — but since the fallback
        // dispatches on address(this), we need separate instances with their own storage.
        // Instead, we deploy separate instances for each precompile.

        MockPrecompile spotBalanceMock = new MockPrecompile();
        MockPrecompile oraclePriceMock = new MockPrecompile();
        MockPrecompile spotPriceMock = new MockPrecompile();
        MockPrecompile l1BlockMock = new MockPrecompile();
        MockPrecompile spotAssetInfoMock = new MockPrecompile();

        vm.etch(address(0x0000000000000000000000000000000000000801), address(spotBalanceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000807), address(oraclePriceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000808), address(spotPriceMock).code);
        vm.etch(address(0x0000000000000000000000000000000000000809), address(l1BlockMock).code);
        vm.etch(address(0x000000000000000000000000000000000000080C), address(spotAssetInfoMock).code);
    }

    function _setDefaultPrices() internal {
        // Set spot prices via the precompile at 0x808
        // We need to write to the storage of the contract etched at 0x808
        // Use vm.store to set the spotPrices mapping

        // spotPrices mapping slot: slot 2 in MockPrecompile
        // mapping(uint32 => uint64) public spotPrices at slot 2
        _setSpotPrice(HYPE_SPOT_MARKET_INDEX, HYPE_RAW_PRICE);
        _setSpotPrice(PURR_SPOT_MARKET_INDEX, PURR_RAW_PRICE);

        // Set L1 block number
        _setL1Block(100);
    }

    function _setSpotPrice(uint32 spotMarketIndex, uint64 rawPrice) internal {
        // MockPrecompile.spotPrices is a mapping at slot 2
        bytes32 slot = keccak256(abi.encode(uint256(spotMarketIndex), uint256(2)));
        vm.store(
            address(0x0000000000000000000000000000000000000808),
            slot,
            bytes32(uint256(rawPrice))
        );
    }

    function _setSpotBalance(address user, uint32 tokenIndex, uint64 total, uint64 hold) internal {
        // MockPrecompile.totalBalances at slot 0, holdBalances at slot 1
        bytes32 key = keccak256(abi.encode(user, tokenIndex));
        bytes32 totalSlot = keccak256(abi.encode(key, uint256(0)));
        bytes32 holdSlot = keccak256(abi.encode(key, uint256(1)));
        vm.store(address(0x0000000000000000000000000000000000000801), totalSlot, bytes32(uint256(total)));
        vm.store(address(0x0000000000000000000000000000000000000801), holdSlot, bytes32(uint256(hold)));
    }

    function _setL1Block(uint64 blockNum) internal {
        // MockPrecompile.l1BlockNumber at slot 4
        // Layout: slot0=totalBalances, slot1=holdBalances, slot2=spotPrices, slot3=oraclePrices, slot4=l1BlockNumber
        vm.store(
            address(0x0000000000000000000000000000000000000809),
            bytes32(uint256(4)),
            bytes32(uint256(blockNum))
        );
    }

    function _deposit(address user, uint256 amount) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit{value: amount}();
    }
}
