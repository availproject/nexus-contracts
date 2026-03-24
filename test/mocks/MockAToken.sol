// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title MockAToken
/// @notice Mock Aave aToken for testing
contract MockAToken is ERC20 {
    address public minter;

    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        minter = msg.sender;
    }

    function mint(address to, uint256 amount) external {
        require(msg.sender == minter, "Only minter");
        _mint(to, amount);
    }

    function setMinter(address _minter) external {
        require(msg.sender == minter, "Only minter");
        minter = _minter;
    }
}
