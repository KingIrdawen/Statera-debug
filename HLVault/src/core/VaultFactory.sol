// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {RebalancingVault} from "./RebalancingVault.sol";

contract VaultFactory {
    address public owner;
    address public pendingOwner;
    address public keeper;
    address public immutable implementation;
    bool public globalPaused;

    mapping(address => address) public vaults; // counterpartToken => vault
    address[] public allVaults;

    event VaultCreated(address indexed vault, address indexed counterpartToken);
    event KeeperUpdated(address indexed newKeeper);
    event OwnershipTransferStarted(address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event GlobalPauseUpdated(bool paused);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _implementation, address _keeper) {
        owner = msg.sender;
        implementation = _implementation;
        keeper = _keeper;
    }

    function createVault(
        address _counterpartToken,
        uint32 _counterpartTokenIndex,
        uint32 _counterpartSpotMarketIndex,
        uint32 _hypeTokenIndex,
        uint32 _hypeSpotMarketIndex,
        uint32 _usdcTokenIndex,
        uint8 _counterpartSzDecimals,
        uint8 _counterpartWeiDecimals,
        uint8 _counterpartEvmDecimals,
        uint256 _maxSingleDepositHype18,
        string calldata _name,
        string calldata _symbol
    ) external onlyOwner returns (address vault) {
        require(vaults[_counterpartToken] == address(0), "vault exists");

        vault = Clones.clone(implementation);

        RebalancingVault(payable(vault)).initialize(
            address(this),
            _counterpartToken,
            _counterpartTokenIndex,
            _counterpartSpotMarketIndex,
            _hypeTokenIndex,
            _hypeSpotMarketIndex,
            _usdcTokenIndex,
            _counterpartSzDecimals,
            _counterpartWeiDecimals,
            _counterpartEvmDecimals,
            _maxSingleDepositHype18,
            _name,
            _symbol
        );

        vaults[_counterpartToken] = vault;
        allVaults.push(vault);

        emit VaultCreated(vault, _counterpartToken);
    }

    function setKeeper(address _keeper) external onlyOwner {
        keeper = _keeper;
        emit KeeperUpdated(_keeper);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "not pending owner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setGlobalPause(bool _paused) external onlyOwner {
        globalPaused = _paused;
        emit GlobalPauseUpdated(_paused);
    }

    function vaultCount() external view returns (uint256) {
        return allVaults.length;
    }
}
