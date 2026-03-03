// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockPermit2
/// @notice Minimal Permit2 implementation for benchmarking
/// @dev Handles the token flow for UniswapV4Router -> Permit2 -> UniversalRouter
contract MockPermit2 {
    using SafeERC20 for IERC20;

    /// @notice Approve a spender to spend tokens on behalf of the caller
    /// @param token The token to approve
    /// @param spender The spender to approve
    function approve(
        address token,
        address spender,
        uint160 /* amount */,
        uint48 /* expiration */
    ) external {
        // Transfer tokens from caller (UniswapV4Router) to this contract
        // This simulates Permit2 holding the tokens
        uint256 balance = IERC20(token).balanceOf(msg.sender);
        IERC20(token).safeTransferFrom(msg.sender, address(this), balance);

        // Approve the spender (UniversalRouter) to spend tokens from this contract
        IERC20(token).forceApprove(spender, type(uint256).max);
    }
}
