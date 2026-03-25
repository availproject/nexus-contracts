// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MockAToken} from "./MockAToken.sol";

/// @title MockAavePool
/// @notice Mock Aave V3 Pool for testing supply functionality
/// @dev Extracted from test/SwapAaveGasProfiler.t.sol
contract MockAavePool {
    using SafeERC20 for IERC20;

    // Track who supplied what amount for each asset
    mapping(address => mapping(address => uint256)) public supplied;

    // Mapping from asset to its corresponding aToken
    mapping(address => address) public aTokenForAsset;

    // Allowed minter (the pool itself)
    address public minter;

    event Supply(address indexed asset, address indexed user, uint256 amount);

    constructor() {
        minter = msg.sender;
    }

    // Set the aToken address for an asset
    function setATokenForAsset(address asset, address aToken) external {
        require(msg.sender == minter, "Only minter");
        aTokenForAsset[asset] = aToken;
    }

    // Internal function to handle supply logic
    function _supply(address asset, uint256 amount, address onBehalfOf) internal {
        supplied[onBehalfOf][asset] += amount;
        address aToken = aTokenForAsset[asset];
        if (aToken != address(0)) {
            MockAToken(aToken).mint(onBehalfOf, amount);
        }
        emit Supply(asset, onBehalfOf, amount);
    }

    // Aave V3 supply function signature
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external {
        // Pull tokens from caller (matches real Aave V3 behavior)
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        _supply(asset, amount, onBehalfOf);
    }

    function getSupplied(address user, address asset) external view returns (uint256) {
        return supplied[user][asset];
    }
}
