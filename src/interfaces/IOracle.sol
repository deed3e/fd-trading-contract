// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

/// @title IOracle
/// @notice Read price of various token
interface IOracle {
    function getPrice(address token) external view returns (uint256);
    function getMultiplePrices(address[] calldata tokens) external view returns (uint256[] memory);
    function postPrices(address[] calldata tokens, uint256[] calldata prices) external;
}
