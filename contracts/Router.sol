// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

// Routers inherited
import './modules/V2SwapRouter.sol';
import './modules/V3SwapRouter.sol';
import './modules/Payments.sol';
import './base/RouterCallbacks.sol';
import '../lib/permitpost/src/interfaces/IPermitPost.sol';

// Helper Libraries
import './libraries/CommandBuilder.sol';
import './libraries/Constants.sol';

import {ERC721} from 'solmate/src/tokens/ERC721.sol';

contract Router is V2SwapRouter, V3SwapRouter, RouterCallbacks {
    using CommandBuilder for bytes[];

    error ExecutionFailed(uint256 commandIndex, bytes message);
    error ETHNotAccepted();
    error TransactionDeadlinePassed();
    error InvalidCommandType(uint256 commandIndex);

    // Command Types
    uint256 constant PERMIT = 0x00;
    uint256 constant TRANSFER = 0x01;
    uint256 constant V3_SWAP_EXACT_IN = 0x02;
    uint256 constant V3_SWAP_EXACT_OUT = 0x03;
    uint256 constant V2_SWAP_EXACT_IN = 0x04;
    uint256 constant V2_SWAP_EXACT_OUT = 0x05;
    uint256 constant SEAPORT = 0x06;
    uint256 constant WRAP_ETH = 0x07;
    uint256 constant UNWRAP_WETH = 0x08;
    uint256 constant SWEEP = 0x09;
    uint256 constant NFTX = 0x0a;
    uint256 constant LOOKS_RARE = 0x0b;

    uint8 constant FLAG_COMMAND_TYPE_MASK = 0x0f;
    uint8 constant COMMAND_INDICES_OFFSET = 8;
    // the first 32 bytes of a dynamic parameter specify the parameter length
    uint8 constant PARAMS_LENGTH_OFFSET = 32;

    address immutable PERMIT_POST;

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert TransactionDeadlinePassed();
        _;
    }

    constructor(
        address permitPost,
        address v2Factory,
        address v3Factory,
        bytes32 pairInitCodeHash,
        bytes32 poolInitCodeHash
    ) V2SwapRouter(v2Factory, pairInitCodeHash) V3SwapRouter(v3Factory, poolInitCodeHash) {
        PERMIT_POST = permitPost;
    }

    /// @param commands A set of concatenated commands, each 8 bytes in length
    /// @param state The state elements that should be used for the input and output of commands
    function execute(uint256 deadline, bytes memory commands, bytes[] memory state)
        public
        payable
        checkDeadline(deadline)
        returns (bytes[] memory)
    {
        bytes8 command;
        uint8 commandType;
        uint8 flags;
        bytes8 indices;
        bool success = true;

        bytes memory output;
        uint256 totalBytes;
        unchecked {
            // Calculates the full length of the `commands` parameter
            totalBytes = commands.length + PARAMS_LENGTH_OFFSET;
        }

        // starts from the 32nd byte, as the first 32 hold the length of `bytes commands`
        // terminates when it has passed the final byte of `commands`
        // each command is 8 bytes, so the end of the loop increments by 8
        for (uint256 byteIndex = PARAMS_LENGTH_OFFSET; byteIndex < totalBytes;) {
            assembly {
                // loads the command at byte number `byteIndex` to process
                command := mload(add(commands, byteIndex))
            }

            flags = uint8(bytes1(command));
            commandType = flags & FLAG_COMMAND_TYPE_MASK;
            indices = bytes8(uint64(command) << COMMAND_INDICES_OFFSET);

            bytes memory inputs = state.buildInputs(indices);
            if (commandType == PERMIT) {
                (bytes memory data) = abi.decode(inputs, (bytes));
                // pass in the msg.sender as the first parameter `from`
                data = bytes.concat(
                    IPermitPost.transferFrom.selector, abi.encodePacked(uint256(uint160(msg.sender))), data
                );
                (success, output) = PERMIT_POST.call(data);
            } else if (commandType == TRANSFER) {
                (address token, address recipient, uint256 value) = abi.decode(inputs, (address, address, uint256));
                Payments.payERC20(token, recipient, value);
            } else if (commandType == V2_SWAP_EXACT_IN) {
                (uint256 amountOutMin, address[] memory path, address recipient) =
                    abi.decode(inputs, (uint256, address[], address));
                output = abi.encode(v2SwapExactInput(amountOutMin, path, recipient));
            } else if (commandType == V2_SWAP_EXACT_OUT) {
                (uint256 amountOut, uint256 amountInMax, address[] memory path, address recipient) =
                    abi.decode(inputs, (uint256, uint256, address[], address));
                output = abi.encode(v2SwapExactOutput(amountOut, amountInMax, path, recipient));
            } else if (commandType == V3_SWAP_EXACT_IN) {
                (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path) =
                    abi.decode(inputs, (address, uint256, uint256, bytes));
                output = abi.encode(v3SwapExactInput(recipient, amountIn, amountOutMin, path));
            } else if (commandType == V3_SWAP_EXACT_OUT) {
                (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path) =
                    abi.decode(inputs, (address, uint256, uint256, bytes));
                output = abi.encode(v3SwapExactOutput(recipient, amountIn, amountOutMin, path));
            } else if (commandType == SEAPORT) {
                (uint256 value, bytes memory data) = abi.decode(inputs, (uint256, bytes));
                (success, output) = Constants.SEAPORT.call{value: value}(data);
            } else if (commandType == NFTX) {
                (uint256 value, bytes memory data) = abi.decode(state.buildInputs(indices), (uint256, bytes));
                (success, output) = Constants.NFTX_ZAP.call{value: value}(data);
            } else if (commandType == SWEEP) {
                (address token, address recipient, uint256 minValue) = abi.decode(inputs, (address, address, uint256));
                Payments.sweepToken(token, recipient, minValue);
            } else if (commandType == WRAP_ETH) {
                (address recipient, uint256 amountMin) = abi.decode(inputs, (address, uint256));
                Payments.wrapETH(recipient, amountMin);
            } else if (commandType == UNWRAP_WETH) {
                (address recipient, uint256 amountMin) = abi.decode(inputs, (address, uint256));
                Payments.unwrapWETH9(recipient, amountMin);
            } else if (commandType == LOOKS_RARE) {
                (uint256 value, bytes memory data, address recipient, address token, uint256 id) =
                    abi.decode(inputs, (uint256, bytes, address, address, uint256));
                (success, output) = Constants.LOOKSRARE_EXCHANGE.call{value: value}(data);
                if (!success) revert ExecutionFailed({commandIndex: LOOKS_RARE, message: output});
                ERC721(token).safeTransferFrom(address(this), recipient, id);
            } else {
                revert InvalidCommandType({commandIndex: (byteIndex - 32) / 8});
            }

            if (!success) revert ExecutionFailed({commandIndex: (byteIndex - 32) / 8, message: output});

            unchecked {
                byteIndex += 8;
            }
        }

        return state;
    }

    receive() external payable {
        if (msg.sender != Constants.WETH9) {
            revert ETHNotAccepted();
        }
    }
}
