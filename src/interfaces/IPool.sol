// SPDX-License-Identifier: MIT

pragma solidity >=0.8.19;

enum Side {
    LONG,
    SHORT
}

interface IPool {
    function increasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _collateral,
        uint256 _sizeChange,
        Side _side
    ) external;

    function decreasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _desiredCollateralReduce,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external;
}
