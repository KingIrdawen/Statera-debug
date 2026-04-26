// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract SharePricingTest is VaultTestBase {
    function test_initialSharePrice() public view {
        uint256 price = vault.sharePriceUsdc8();
        assertEq(price, 1e8);
    }

    function test_previewDeposit_firstDeposit() public view {
        uint256 shares = vault.previewDeposit(1 ether);
        assertEq(shares, 25e18);
    }

    function test_deposit_mintsShares() public {
        uint256 shares = _deposit(alice, 1 ether);
        assertEq(shares, 25e18);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.totalSupply(), shares);
    }

    function test_deposit_multipleDepositors() public {
        uint256 shares1 = _deposit(alice, 1 ether);
        uint256 shares2 = _deposit(bob, 2 ether);
        assertGt(shares2, shares1);
        assertEq(vault.totalSupply(), shares1 + shares2);
    }

    function test_deposit_zeroReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.ZeroDeposit.selector));
        vault.deposit{value: 0}();
    }

    function test_deposit_exceedsMaxReverts() public {
        vm.deal(alice, 2000 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.ExceedsMax.selector));
        vault.deposit{value: 1001 ether}();
    }

    function test_deposit_blockedDuringRebalance() public {
        _deposit(alice, 1 ether);

        // Start rebalance via advanceRebalance (100% HYPE on EVM = massive drift)
        vm.prank(keeper);
        vault.advanceRebalance();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.CycleInProgress.selector));
        vault.deposit{value: 1 ether}();
    }

    function test_deposit_blockedDuringSettlement() public {
        uint256 shares = _deposit(alice, 10 ether);

        // Request redeem and start settlement with TOKEN on Core
        // (so the settlement doesn't complete in one call)
        vm.prank(alice);
        vault.requestRedeem(shares);
        _setSpotBalance(address(vault), PURR_TOKEN_INDEX, 12000000000, 0);
        vm.prank(keeper);
        vault.advanceBatchSettlement(); // AWAITING_SELL

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.SettlementInProgress.selector));
        vault.deposit{value: 1 ether}();
    }

    function test_deposit_blockedWhenPaused() public {
        vm.prank(owner);
        vault.pause();

        vm.prank(alice);
        vm.expectRevert();
        vault.deposit{value: 1 ether}();
    }

    function test_deposit_blockedWhenDepositsDisabled() public {
        vm.prank(keeper);
        vault.setDepositsEnabled(false);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.DepositsDisabled.selector));
        vault.deposit{value: 1 ether}();
    }

    function test_grossAssets_onlyEvmHype() public {
        _deposit(alice, 10 ether);
        uint256 assets = vault.grossAssets();
        assertEq(assets, 25000000000);
    }

    function test_grossAssets_withCoreBalances() public {
        _deposit(alice, 10 ether);

        _setSpotBalance(address(vault), HYPE_TOKEN_INDEX, 5e8, 0);
        _setSpotBalance(address(vault), USDC_TOKEN_INDEX, 10000000000, 0);

        uint256 assets = vault.grossAssets();
        assertEq(assets, 47500000000);
    }

    function test_name_and_symbol() public view {
        assertEq(vault.name(), "HLVault HYPE-PURR");
        assertEq(vault.symbol(), "hlPURR");
    }
}
