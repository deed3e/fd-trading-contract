// // SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import "lib/forge-std/src/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {Oracle} from "../src/oracle/Oracle.sol";
import {WETH9} from "../src/helper/WETH9.sol";
import {Pool, Fee, TokenWeight} from "../src/pool/Pool.sol";
import {Router} from "../src/pool/Router.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract Push is Script {
    Oracle _oracle;
    address _reporter = address(0xd57F41BF686b2Ffd2C66Eb939BF991499775f40C);
    //Demo _demo;
    MockERC20 _eth;
    MockERC20 _usdt;
    MockERC20 _btc;

    WETH9 _weth;

    Pool _pool;
    Router _router;
    LPToken _lp;

    function run() public {
        uint256 owner = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(owner);
        _oracle = new Oracle();
        _oracle.addReporter(_reporter);
        _eth = new MockERC20("ETH", "ETH", 18);
        _usdt = new MockERC20("Tether USD", "USDT", 6);
        _btc = new MockERC20("BTC", "BTC", 8);
        _weth = new WETH9();
        _oracle.configToken(address(_btc), 8, 8);
        _oracle.configToken(address(_eth), 18, 8);
        _oracle.configToken(address(_weth), 18, 8);
        _oracle.configToken(address(_usdt), 6, 8);
        _pool = new Pool(address(_oracle));
        _lp = new LPToken("LP","LP",address(_pool));
        _pool.setLpToken(address(_lp));
        _pool.addToken(address(_btc), false);
        _pool.addToken(address(_eth), false);
        _pool.addToken(address(_usdt), true);
        _pool.addToken(address(_weth), false);
        Fee memory _fee = Fee(25000000, 20000000, 40000000, 10000000, 50000000, 1000000000);
        _pool.setFee(_fee);
        TokenWeight[] memory _tokenWeight = new TokenWeight[](4);
        _tokenWeight[0] = TokenWeight(address(_eth), 200);
        _tokenWeight[1] = TokenWeight(address(_btc), 200);
        _tokenWeight[2] = TokenWeight(address(_usdt), 500);
        _tokenWeight[3] = TokenWeight(address(_weth), 100);
        _pool.setTargetWeight(_tokenWeight);
        _router = new Router(address(_pool),address(_weth),address(_lp));

        console.log("oracle :", address(_oracle));
        console.log("eth :", address(_eth));
        console.log("btc :", address(_btc));
        console.log("usdt :", address(_usdt));
        console.log("weth :", address(_weth));
        console.log("pool :", address(_pool));
        console.log("router :", address(_router));
        console.log("lp :", address(_lp));

        vm.stopBroadcast();
    }
}
