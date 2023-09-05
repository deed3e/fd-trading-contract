// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

interface IETHUnwrapper {
    function unwrap(uint256 _amount, address _to) external;
}
