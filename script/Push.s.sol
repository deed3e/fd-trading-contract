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
import {OrderManager} from "../src/orders/OrderManager.sol";

contract Push is Script {
    Oracle oracle;
    address reporter = address(0xd57F41BF686b2Ffd2C66Eb939BF991499775f40C);
    MockERC20 eth;
    MockERC20 usdc;
    MockERC20 btc;
    WETH9 weth;

    Pool pool;
    Router router;
    LPToken lp;
    OrderManager orderManager;

    function run() public {
        uint256 owner = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(owner);
        // oracle = new Oracle();
        // oracle.addReporter(reporter);
        // eth = new MockERC20("ETH", "ETH", 18);
        // usdc = new MockERC20("USD Coin", "USDC", 6);
        // btc = new MockERC20("BTC", "BTC", 8);
        // weth = new WETH9();
        // oracle.configToken(address(btc), 8, 8);
        // oracle.configToken(address(eth), 18, 8);
        // oracle.configToken(address(weth), 18, 8);
        // oracle.configToken(address(usdc), 6, 8);
        // pool = new Pool(address(oracle),1000000,3600);
        // lp = new LPToken("LP","LP",address(pool));
        // pool.setLpToken(address(lp));
        // pool.addToken(address(btc), false);
        // pool.addToken(address(eth), false);
        // pool.addToken(address(usdc), true);
        // pool.addToken(address(weth), false);
        // Fee memory fee =
        //     Fee(25000000, 20000000, 40000000, 10000000, 50000000, 1000000000, 5000000000000000000000000000000, 10000000);
        // pool.setFee(fee);
        // TokenWeight[] memory tokenWeight = new TokenWeight[](4);
        // tokenWeight[0] = TokenWeight(address(eth), 200);
        // tokenWeight[1] = TokenWeight(address(btc), 200);
        // tokenWeight[2] = TokenWeight(address(usdc), 600);
        // tokenWeight[3] = TokenWeight(address(weth), 100);
        // pool.setTargetWeight(tokenWeight);
        // router = new Router(address(pool),address(weth),address(lp));

        // orderManager = new OrderManager(address(oracle),address(pool), 1e16 );
        // pool.setOrderManager(address(orderManager));
        // pool.setMaxLeverage(50);

        // case1
        pool = new Pool(address(0x1E16D408a6ae4E2a867cd33F15cb7E17441139c1),1000000,3600);
        lp = new LPToken("LP","LP",address(pool));
        pool.setLpToken(address(lp));
        pool.addToken(address(0xBD4EE5db59c8d238c99c350002f199CCc0e1CAaE), false);
        pool.addToken(address(0xacB66a930079F26980933E148c7718bbAFD66a45), false);
        pool.addToken(address(0x56EB53dC2C58E2842b00a970F70bFD4fb3936657), true);
        pool.addToken(address(0x5f02a71acD8a8B692Db0c237414d52eC7c6F8C6c), false);
        Fee memory fee =
            Fee(25000000, 20000000, 40000000, 10000000, 50000000, 1000000000, 5000000000000000000000000000000, 10000000);
        pool.setFee(fee);
        TokenWeight[] memory tokenWeight = new TokenWeight[](4);
        tokenWeight[0] = TokenWeight(address(0xBD4EE5db59c8d238c99c350002f199CCc0e1CAaE), 200);
        tokenWeight[1] = TokenWeight(address(0xacB66a930079F26980933E148c7718bbAFD66a45), 200);
        tokenWeight[2] = TokenWeight(address(0x56EB53dC2C58E2842b00a970F70bFD4fb3936657), 600);
        tokenWeight[3] = TokenWeight(address(0x5f02a71acD8a8B692Db0c237414d52eC7c6F8C6c), 100);
        pool.setTargetWeight(tokenWeight);
        router = new Router(address(pool),address(0x5f02a71acD8a8B692Db0c237414d52eC7c6F8C6c),address(lp));

        pool.setMaxLeverage(50);
        orderManager = new OrderManager(address(0x1E16D408a6ae4E2a867cd33F15cb7E17441139c1),address(pool), 1e16 );
        pool.setOrderManager(address(orderManager));

        // case2
        // orderManager =
        // new OrderManager(address(0x1E16D408a6ae4E2a867cd33F15cb7E17441139c1),address(0x006Df49bde510578dE88b75AEe4754cc86bFAFD0), 1e16 );
        // Pool(0x006Df49bde510578dE88b75AEe4754cc86bFAFD0).setOrderManager(address(orderManager));

        console.log("oracle :", address(oracle));
        console.log("order manager :", address(orderManager));
        console.log("eth :", address(eth));
        console.log("btc :", address(btc));
        console.log("usdc :", address(usdc));
        console.log("weth :", address(weth));
        console.log("pool :", address(pool));
        console.log("router :", address(router));
        console.log("lp :", address(lp));

        vm.stopBroadcast();
    }
}
