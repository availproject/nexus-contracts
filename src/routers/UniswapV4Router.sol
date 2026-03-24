// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IActionRouter} from "../interfaces/IActionRouter.sol";
import {INexusSettler} from "../interfaces/INexusSettler.sol";
import {UniversalRouter} from "lib/universal-router/contracts/UniversalRouter.sol";
import {Commands} from "lib/universal-router/contracts/libraries/Commands.sol";
import {PoolKey} from "lib/v4-core/src/types/PoolKey.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {IV4Router} from "lib/v4-periphery/src/interfaces/IV4Router.sol";
import {SafeCast} from "lib/v4-core/src/libraries/SafeCast.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {Currency} from "lib/v4-core/src/types/Currency.sol";

//Uses Uniswap Universal Router for executing swap commands.
//Currently multihop swaps are not implemented, only exact in and exact out flows.
contract UniswapV4Router is IActionRouter {
    error InvalidPreviousData();

    UniversalRouter public immutable ROUTER;
    IPermit2 public immutable PERMIT_2;

    struct Swap {
        PoolKey key;
        uint128 maxAmountIn;
        uint128 minAmountOut;
        bool zeroForOne;
        bool exactOut;
        uint256 deadline;
        address destination;
    }

    constructor(address _router, address _permit2) {
        ROUTER = UniversalRouter(payable(_router));
        PERMIT_2 = IPermit2(_permit2);
    }

    function execute(INexusSettler.Action calldata action, bytes calldata previousData)
        external
        returns (bytes memory)
    {
        if (action.actionType != INexusSettler.ActionType.SWAP) {
            revert("Invalid action type");
        }
        Swap memory swap = abi.decode(action.callData, (Swap));
        uint128 maxAmountIn = swap.maxAmountIn;
        address tokenIn = swap.zeroForOne ? Currency.unwrap(swap.key.currency0) : Currency.unwrap(swap.key.currency1);
        Currency tokenOut = swap.zeroForOne ? swap.key.currency1 : swap.key.currency0;

        if (maxAmountIn == 0) {
            if (previousData.length != 32) revert InvalidPreviousData();
            uint256 v;
            assembly {
                v := calldataload(previousData.offset)
            }
            maxAmountIn = SafeCast.toUint128(v);
        }

        //Expects sender to have approved this contract
        IERC20(tokenIn).transferFrom(msg.sender, address(this), maxAmountIn);

        // Step 1: Approve Permit2 to spend tokens from this contract (one-time, max approval)
        if (IERC20(tokenIn).allowance(address(this), address(PERMIT_2)) < maxAmountIn) {
            IERC20(tokenIn).approve(address(PERMIT_2), type(uint256).max);
        }

        // Step 2: Use Permit2 to approve ROUTER to spend tokens
        // Set expiration to max uint48 for persistent approval
        PERMIT_2.approve(tokenIn, address(ROUTER), type(uint160).max, type(uint48).max);

        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));
        bytes[] memory inputs = new bytes[](1);

        bytes memory actions = abi.encodePacked(
            uint8(swap.exactOut ? Actions.SWAP_EXACT_OUT_SINGLE : Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory params = new bytes[](3);
        params[0] = swap.exactOut
            ? abi.encode(
                IV4Router.ExactOutputSingleParams({
                    poolKey: swap.key,
                    zeroForOne: swap.zeroForOne,
                    amountOut: swap.minAmountOut,
                    amountInMaximum: maxAmountIn,
                    hookData: bytes("")
                })
            )
            : abi.encode(
                IV4Router.ExactInputSingleParams({
                    poolKey: swap.key,
                    zeroForOne: swap.zeroForOne,
                    amountIn: maxAmountIn,
                    amountOutMinimum: swap.minAmountOut,
                    hookData: bytes("")
                })
            );

        params[1] = abi.encode(
            tokenIn,
            //Max amount to pay
            maxAmountIn
        );

        params[2] = abi.encode(
            tokenOut,
            //Min amount to take
            swap.minAmountOut
        );

        inputs[0] = abi.encode(actions, params);

        ROUTER.execute(commands, inputs, swap.deadline);

        //TODO: Currently no need to check this, as uniswap contracts already do this during TAKE_ALL, but we trust their contract in this case.
        //require(amountOut >= swap.minAmountOut, "Insufficient output amount");

        uint256 amountOut = (tokenOut).balanceOf(address(this));
        IERC20(Currency.unwrap(tokenOut)).transfer(swap.destination, amountOut);

        //TODO: Cheaper alternative to abi.encode.
        return abi.encode(amountOut);
    }
}
