// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

enum Side {
    LONG,
    SHORT
}

/// @title IPool
interface IPool {
    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to) external;
    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to) external;
    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, address _to) external;

    function increasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _collateral,
        uint256 _sizeChanged,
        Side _side
    ) external;

    function decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external;
}
