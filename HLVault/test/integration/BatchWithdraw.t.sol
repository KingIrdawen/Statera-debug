// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./VaultTestBase.sol";
import {RebalancingVault} from "../../src/core/RebalancingVault.sol";

contract BatchWithdrawTest is VaultTestBase {
    function test_requestRedeem() public {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        uint256 redeemId = vault.requestRedeem(shares);

        assertEq(redeemId, 0);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(vault)), shares);
        assertEq(vault.escrowedShares(), shares);
        assertEq(vault.circulatingShares(), 0);
    }

    function test_requestRedeem_zeroReverts() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.NoShares.selector));
        vault.requestRedeem(0);
    }

    function test_requestRedeem_insufficientReverts() public {
        _deposit(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(RebalancingVault.Insufficient.selector));
        vault.requestRedeem(type(uint256).max);
    }

    function test_multipleRedeemRequests_sameBatch() public {
        uint256 sharesAlice = _deposit(alice, 10 ether);
        uint256 sharesBob = _deposit(bob, 5 ether);

        vm.prank(alice);
        uint256 id1 = vault.requestRedeem(sharesAlice);
        vm.prank(bob);
        uint256 id2 = vault.requestRedeem(sharesBob);

        assertEq(id1, 0);
        assertEq(id2, 1);
        assertEq(vault.escrowedShares(), sharesAlice + sharesBob);
    }

    function test_getUserRedeemIds() public {
        uint256 shares = _deposit(alice, 10 ether);
        uint256 half = shares / 2;
        uint256 quarter = shares / 4;
        vm.startPrank(alice);
        vault.requestRedeem(half);
        vault.requestRedeem(quarter);
        vm.stopPrank();

        uint256[] memory ids = vault.getUserRedeemIds(alice);
        assertEq(ids.length, 2);
        assertEq(ids[0], 0);
        assertEq(ids[1], 1);
    }
}
