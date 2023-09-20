// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {IPool} from "../interfaces/IPool.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {SafeERC20, IERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title Liquidity Router
/// @notice helper to add/remove liquidity and wrap/unwrap ETH as needed
contract Router {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeERC20 for ILPToken;

    address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    IPool public pool;
    IWETH public weth;
    ILPToken public lpToken;

    constructor(address _pool, address _weth, address _lpToken) {
        require(_pool != address(0), "ETHHelper:zeroAddress");
        require(_weth != address(0), "ETHHelper:zeroAddress");

        pool = IPool(_pool);
        weth = IWETH(_weth);
        lpToken = ILPToken(_lpToken);
    }

    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount) external payable {
        address payToken;
        (payToken, _token) = _token == ETH ? (ETH, address(weth)) : (_token, _token);
        IERC20 token = IERC20(_token);
        if (payToken == ETH) {
            weth.deposit{value: _amountIn}();
        } else {
            token.safeTransferFrom(msg.sender, address(this), _amountIn);
        }
        token.safeIncreaseAllowance(address(pool), _amountIn);
        pool.addLiquidity(_token, _amountIn, _minLpAmount, msg.sender);
    }

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut) external payable {
        lpToken.safeTransferFrom(msg.sender, address(this), _lpAmount);
        lpToken.safeIncreaseAllowance(address(pool), _lpAmount);
        if (_tokenOut == ETH) {
            uint256 balanceBefore = weth.balanceOf(address(this));
            pool.removeLiquidity(address(weth), _lpAmount, _minOut, address(this));
            uint256 received = weth.balanceOf(address(this)) - balanceBefore;
            weth.withdraw(received);
            _safeTransferETH(msg.sender, received);
        } else {
            pool.removeLiquidity(_tokenOut, _lpAmount, _minOut, msg.sender);
        }
    }

    function swap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minOut) external payable {
        (address outToken, address receiver) = _toToken == ETH ? (address(weth), address(this)) : (_toToken, msg.sender);
        address inToken;
        if (_fromToken == ETH) {
            _amountIn = msg.value;
            inToken = address(weth);
            weth.deposit{value: _amountIn}();
            weth.safeTransfer(address(pool), _amountIn);
        } else {
            inToken = _fromToken;
            IERC20(inToken).safeTransferFrom(msg.sender, address(pool), _amountIn);
        }

        uint256 amountOut = _doSwap(inToken, outToken, _amountIn, _minOut, receiver);
        if (outToken == address(weth) && _toToken == ETH) {
            weth.withdraw(amountOut);
            _safeTransferETH(msg.sender, amountOut);
        }
    }

    function _doSwap(address _fromToken, address _toToken, uint256 _amountIn, uint256 _minOut, address _receiver)
        internal
        returns (uint256 amountOut)
    {
        IERC20 tokenOut = IERC20(_toToken);
        uint256 priorBalance = tokenOut.balanceOf(_receiver);
        pool.swap(_fromToken, _toToken, _amountIn, _minOut, _receiver);
        amountOut = tokenOut.balanceOf(_receiver) - priorBalance;
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = to.call{value: amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    receive() external payable {}
}
