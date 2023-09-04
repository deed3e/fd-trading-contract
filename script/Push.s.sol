// // SPDX-License-Identifier: UNLICENSED
 pragma solidity >=0.8.19;
 import 'lib/forge-std/src/Script.sol';
 import {OracleV2} from '../src/oracle/OracleV2.sol';
 import {Demo} from "../src/Demo.sol";
 import {MockERC20} from "../test/mocks/MockERC20.sol";

contract Push is Script {
    OracleV2 _oracle;
    //Demo _demo;
    MockERC20 _mockERC20;
    function run() public {
        uint256 owner = vm.envUint('PRIVATE_KEY');
        vm.startBroadcast(owner);
       // _oracle = new OracleV2();
        _mockERC20 = new MockERC20("FDex", "FDex", 18);
        vm.stopBroadcast();
    }
}