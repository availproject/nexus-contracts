// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";
import {IHooks} from "lib/v4-core/src/interfaces/IHooks.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {MockPoolManager} from "./MockPoolManager.sol";
import "lib/forge-std/src/console2.sol";

/// @title MockUniversalRouter
/// @notice Simulates UniversalRouter.execute() for V4_SWAP commands
/// @dev Minimal implementation for benchmarking NexusSettler swap flow
contract MockUniversalRouter {
    using SafeERC20 for IERC20;

    // V4_SWAP command constant from Commands.sol
    uint8 public constant V4_SWAP = 0x10;

    // Action constants from Actions.sol
    uint8 public constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 public constant SWAP_EXACT_OUT_SINGLE = 0x08;
    uint8 public constant SETTLE_ALL = 0x0c;
    uint8 public constant TAKE_ALL = 0x0f;

    MockPoolManager public immutable POOL_MANAGER;
    address public immutable PERMIT2;

    event Execute(bytes commands, uint256 deadline);
    event V4SwapExecuted(
        address indexed sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    constructor(address poolManager, address permit2) {
        POOL_MANAGER = MockPoolManager(poolManager);
        PERMIT2 = permit2;
    }

    /// @notice Execute commands - only handles V4_SWAP command
    /// @param commands Encoded command bytes
    /// @param inputs Array of encoded inputs for each command
    /// @param deadline Transaction deadline
    function execute(
        bytes calldata commands,
        bytes[] calldata inputs,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "Transaction expired");

        emit Execute(commands, deadline);

        // Debug: log commands length and inputs length
        console2.log("Commands length:", commands.length);
        console2.log("Inputs length:", inputs.length);

        for (uint256 i = 0; i < commands.length; ) {
            uint8 command = uint8(commands[i]);
            console2.log("Command:", command);

            if (command == V4_SWAP) {
                console2.log("Calling _executeV4Swap");
                _executeV4Swap(inputs[i]);
            } else {
                revert("Unsupported command");
            }

            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal function to execute V4 swap
    /// @param input Encoded swap parameters
    function _executeV4Swap(bytes calldata input) internal {
        console2.log("_executeV4Swap called, input length:", input.length);
        
        // Decode actions and params from input
        // Format: abi.encode(actions, params)
        (
            bytes memory actions,
            bytes[] memory params
        ) = abi.decode(input, (bytes, bytes[]));

        console2.log("Decoded actions length:", actions.length);
        console2.log("Decoded params length:", params.length);

        // Parse the first action to determine swap type
        uint8 action = uint8(actions[0]);

        bool exactOut = (action == SWAP_EXACT_OUT_SINGLE);
        console2.log("exactOut:", exactOut);
        console2.log("params[0] length:", params[0].length);
        console2.log("About to call _decodeSwapParams");

        // Try-catch to get more info on decode failure
        PoolKey memory key;
        bool zeroForOne;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint256 amountOut;
        uint256 amountInMaximum;
        
        // Pass full params array to access params[1] and params[2]
        try this.decodeParams(params, exactOut) returns (
            PoolKey memory k,
            bool zfo,
            uint256 amtIn,
            uint256 amtOutMin,
            uint256 amtOut,
            uint256 amtInMax
        ) {
            key = k;
            zeroForOne = zfo;
            amountIn = amtIn;
            amountOutMinimum = amtOutMin;
            amountOut = amtOut;
            amountInMaximum = amtInMax;
        } catch {
            console2.log("DECODE FAILED");
            // Revert with more info
            revert("Decode failed - check params encoding");
        }
        console2.log("_decodeSwapParams returned successfully");

        console2.log("Decoded swap params");
        console2.log("zeroForOne:", zeroForOne);
        console2.log("amountIn:", amountIn);

        // Debug: print first few bytes of params
        bytes memory first4 = new bytes(4);
        for (uint i = 0; i < 4 && i < params[0].length; i++) {
            first4[i] = params[0][i];
        }
        console2.log("First 4 bytes of params:", uint32(bytes4(first4)));
        console2.log("Params length:", params[0].length);

        // Get settle and take params
        (address settleToken, uint256 settleAmount) = abi.decode(
            params[1],
            (address, uint256)
        );
        (address takeToken, uint256 takeAmount) = abi.decode(
            params[2],
            (address, uint256)
        );

        console2.log("settleToken:", settleToken);
        console2.log("takeToken:", takeToken);
        console2.log("PERMIT2:", PERMIT2);

        // Determine actual amounts
        uint256 actualAmountIn = exactOut ? amountInMaximum : amountIn;
        uint256 minAmountOut = exactOut ? amountOut : amountOutMinimum;

        console2.log("actualAmountIn:", actualAmountIn);
        console2.log("About to transfer from PERMIT2");

        // Transfer input tokens from Permit2 (which should hold tokens after UniswapV4Router
        // transfers from sender to itself and sets up PERMIT2 approvals)
        IERC20(settleToken).safeTransferFrom(
            PERMIT2,
            address(this),
            actualAmountIn
        );

        console2.log("Transfer from PERMIT2 successful");

        // Approve pool manager
        IERC20(settleToken).forceApprove(
            address(POOL_MANAGER),
            actualAmountIn
        );

        // Execute swap via pool manager
        uint256 outputAmount = POOL_MANAGER.swap(
            key,
            zeroForOne,
            actualAmountIn,
            minAmountOut
        );

        // Transfer output tokens to caller
        IERC20(takeToken).safeTransfer(msg.sender, outputAmount);

        emit V4SwapExecuted(
            msg.sender,
            settleToken,
            takeToken,
            actualAmountIn,
            outputAmount
        );
    }

    /// @notice Decode swap parameters based on swap type
    /// @param params Full params array (params[1]=settle, params[2]=take)
    /// @param exactOut Whether this is an exact output swap
    /// @return key Pool key
    /// @return zeroForOne Swap direction
    /// @return amountIn Input amount (for exact in)
    /// @return amountOutMinimum Minimum output (for exact in)
    /// @return amountOut Output amount (for exact out)
    /// @return amountInMaximum Maximum input (for exact out)
    function _decodeSwapParams(
        bytes[] memory params,
        bool exactOut
    )
        public
        pure
        returns (
            PoolKey memory key,
            bool zeroForOne,
            uint256 amountIn,
            uint256 amountOutMinimum,
            uint256 amountOut,
            uint256 amountInMaximum
        )
    {
        // params[1] = (settleToken, settleAmount) - input token and amount
        // params[2] = (takeToken, takeAmount) - output token and amount
        (address settleToken, uint256 settleAmount) = abi.decode(
            params[1],
            (address, uint256)
        );
        (address takeToken, uint256 takeAmount) = abi.decode(
            params[2],
            (address, uint256)
        );

        // Determine zeroForOne by comparing token addresses
        // zeroForOne = tokenIn (settle) < tokenOut (take) based on V4's sorted pool requirement
        zeroForOne = settleToken < takeToken;

        // Build PoolKey from tokens (use default fee/tickSpacing/hooks)
        key = PoolKey({
            currency0: Currency.wrap(zeroForOne ? settleToken : takeToken),
            currency1: Currency.wrap(zeroForOne ? takeToken : settleToken),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Set amounts based on exactIn/exactOut
        if (exactOut) {
            // exactOut: amountOut is what we want, amountInMaximum is max we can pay
            amountOut = takeAmount;
            amountInMaximum = settleAmount;
            amountIn = 0;
            amountOutMinimum = 0;
        } else {
            // exactIn: amountIn is what we pay, amountOutMinimum is min we accept
            amountIn = settleAmount;
            amountOutMinimum = takeAmount;
            amountOut = 0;
            amountInMaximum = 0;
        }
    }

    /// @notice External wrapper for decode to enable try-catch
    /// @param params Full params array (params[0]=swapParams, params[1]=settle, params[2]=take)
    /// @param exactOut Whether this is an exact output swap
    function decodeParams(
        bytes[] memory params,
        bool exactOut
    )
        external
        pure
        returns (
            PoolKey memory key,
            bool zeroForOne,
            uint256 amountIn,
            uint256 amountOutMinimum,
            uint256 amountOut,
            uint256 amountInMaximum
        )
    {
        return _decodeSwapParams(params, exactOut);
    }
}
