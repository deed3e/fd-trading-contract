// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

/// @title IPool
interface IPool {
    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to) external;
    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to) external;
    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, address _to) external;
}
