// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Oracle, TokenConfig} from "../src/oracle/Oracle.sol";
import {Pool} from "../src/pool/Pool.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {WETH9} from "../src/helper/WETH9.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {LiquidityRouter} from "../src/pool/LiquidityRouter.sol";

contract Poolz is Test {
    Oracle public oracle;
    Pool public pool;
    LiquidityRouter public router;
    //OrderManager public orderManager;

    LPToken public lp;
    MockERC20 public btc;
    MockERC20 public eth;
    WETH9 public weth;

    address public reporter = vm.addr(1);
    address public deployper = vm.addr(2);

    address public linda = vm.addr(3);
    address public alice = vm.addr(4);
    address public mike = vm.addr(5);
    address public deedee = vm.addr(6);

    mapping(address => bool) public isReporter;

    function setUp() public {
        vm.startBroadcast(address(deployper));
        btc = new MockERC20("BTC","BTC",8);
        eth = new MockERC20("ETH","ETH",18);
        weth = new WETH9();
        oracle = new Oracle();
        oracle.addReporter(reporter);
        oracle.configToken(address(btc), 8, 8);
        oracle.configToken(address(eth), 18, 8);
        oracle.configToken(address(weth), 18, 8);
        pool = new Pool(address(oracle));
        lp = new LPToken("LP","LP",address(pool));
        pool.setLpToken(address(lp));
        pool.addToken(address(btc), false);
        pool.addToken(address(eth), false);
        pool.addToken(address(weth), false);
        router = new LiquidityRouter(address(pool),address(weth),address(lp));
        //=====
        //orderManager = new OrderManager();
        //orderManager.setOracle(address(oracle));
        //orderManager.setPool(address(pool));

        //pool.setOrderManager(address(orderManager));
        //pool.setMaxLeverage(50);

        //=====
        vm.stopBroadcast();
        vm.startBroadcast(address(reporter));
        address[] memory addresses = new address[](3);
        addresses[0] = address(btc);
        addresses[1] = address(eth);
        addresses[2] = address(weth);

        uint256[] memory prices = new uint256[](3);
        prices[0] = 25000e8;
        prices[1] = 1700e8;
        prices[2] = 220e8;
        oracle.postPrices(addresses, prices);
        vm.stopBroadcast();
    }

    function addLiquidity() public {
        // // linda add
        // vm.startBroadcast(linda);
        // btc.mint(1000 * 1e8);
        // btc.approve(address(pool), type(uint256).max);
        // pool.addLiquidity(address(btc), 100e8, 0, linda);
        // vm.stopBroadcast();

        // alice add
        // vm.startBroadcast(alice);
        // eth.mint(100e18);
        // eth.approve(address(router), type(uint256).max);
        // router.addLiquidity(address(eth), 10e18, 0, alice);
        // vm.stopBroadcast();

        //mike add
        vm.startBroadcast(mike);
        vm.deal(mike, 100e18);
        router.addLiquidityETH{value: 100e18}(0, mike);
        uint256 vault = pool.getPoolValue();
        console.log("vault :", vault);
         vm.stopBroadcast();
    }

    // function testRemoveLiquidity() public {
    //     addLiquidity();
    //     // alice remove
    //     vm.startBroadcast(alice);
    //     lp.approve(address(pool), lp.balanceOf(alice));
    //     vm.stopBroadcast();
    //     pool.removeLiquidity(address(eth), lp.balanceOf(alice), 0, alice);
    //     console.log("balance alice", eth.balanceOf(alice));
    // }

    function testRemoveLiquidityETH() public {
        addLiquidity();
        // MIKE remove
         vm.startBroadcast(mike);
        lp.approve(address(router), lp.balanceOf(mike));
        router.removeLiquidityETH(lp.balanceOf(mike), 0, payable(mike));
        console.log("balance mike", mike.balance);
    }

    // function testSwap() public {
    //     addLiquidity();
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     btc.mint(50e8);
    //     btc.approve(address(pool), btc.balanceOf(mike));
    //     console.log("balance eth mike", btc.balanceOf(mike));
    //     pool.swap(address(btc), address(eth), 1e8, 0, address(mike));
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     console.log("rs need = 25000/1700 ");
    //     vm.stopBroadcast();
    // }

    // function testLongPosition() public {
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     vm.roll(1);
    //     eth.mint(50 * 1e18);
    //     eth.approve(address(orderManager), eth.balanceOf(mike));
    //     orderManager.placeOrder(
    //         PositionType.INCREASE, Side.LONG, address(btc), address(eth), 10 * 1e18, 10e39, 200 * 1e18, OrderType.MARKET
    //     );
    //     vm.roll(2);
    //     orderManager.executeOrder(1);
    //     vm.stopBroadcast();

    //     // change price
    //     vm.startBroadcast(address(reporter));
    //     address[] memory addresses = new address[](2);
    //     addresses[0] = address(btc);
    //     addresses[1] = address(eth);

    //     uint256[] memory prices = new uint256[](2);
    //     prices[0] = 220 * 1e18;
    //     prices[1] = 100 * 1e18;
    //     oracle.postPrices(addresses, prices);
    //     vm.stopBroadcast();

    //     // check profit
    //     vm.startBroadcast(mike);
    //     vm.roll(3);
    //     orderManager.placeOrder(
    //         PositionType.DECREASE, Side.LONG, address(btc), address(eth), 0, 10e39, 220 * 1e18, OrderType.MARKET
    //     );
    //     vm.roll(4);
    //     orderManager.executeOrder(2);
    //     vm.roll(5);
    //     console.log("balance btc mike", btc.balanceOf(mike));
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     vm.stopBroadcast();
    // }

    // function testCaseLiquidate() public {
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     vm.roll(1);
    //     eth.mint(50 * 1e18);
    //     eth.approve(address(orderManager), eth.balanceOf(mike));
    //     orderManager.placeOrder(
    //         PositionType.INCREASE, Side.LONG, address(btc), address(eth), 10 * 1e18, 10e39, 200 * 1e18, OrderType.MARKET
    //     );
    //     vm.roll(2);
    //     orderManager.executeOrder(1);
    //     vm.stopBroadcast();

    //     // change price
    //     vm.startBroadcast(address(reporter));
    //     address[] memory addresses = new address[](2);
    //     addresses[0] = address(btc);
    //     addresses[1] = address(eth);

    //     uint256[] memory prices = new uint256[](2);
    //     prices[0] = 182 * 1e18;
    //     prices[1] = 100 * 1e18;
    //     oracle.postPrices(addresses, prices);
    //     vm.stopBroadcast();

    //     // check balance after liquidate
    //     vm.roll(3);
    //     vm.startBroadcast(deedee);
    //     pool.liquidatePosition(address(mike), address(btc), address(eth), Side.LONG);
    //     console.log("balance eth deedee", eth.balanceOf(deedee));
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     vm.stopBroadcast();
    // }
}
