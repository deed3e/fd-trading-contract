// // SPDX-License-Identifier: UNLICENSED
// pragma solidity >=0.8.19;

// import {Test, console} from "forge-std/Test.sol";
// import {OracleV2} from "../src/oracle/OracleV2.sol";
// import {Pool} from "../src/pool/Pool.sol";
// import {LPToken} from "../src/tokens/LPToken.sol";
// import {MockERC20} from "./mocks/MockERC20.sol";
// import {Side} from "../src/interfaces/IPool.sol";

// contract CounterTest is Test {
//     OracleV2 public oracle;
//     Pool public pool;
//     OrderManager public orderManager;

//     LPToken public lp;
//     MockERC20 public btc;
//     MockERC20 public eth;

//     address public reporter = vm.addr(1);
//     address public deployper = vm.addr(2);

//     address public linda = vm.addr(3);
//     address public alice = vm.addr(4);
//     address public mike = vm.addr(5);
//     address public deedee = vm.addr(6);

//     mapping(address => bool) public isReporter;

//     function setUp() public {
//         vm.startBroadcast(address(deployper));
//         btc = new MockERC20("BTC","BTC",18);
//         eth = new MockERC20("ETH","ETH",18);
//         oracle = new OracleV2();
//         oracle.addReporter(reporter);
//         console.log("a",oracle.isReporter(reporter));
//         pool = new Pool(address(oracle));
//         lp = new LPToken("LP","LP",address(pool));
//         pool.setLpToken(address(lp));
//         pool.addToken(address(btc), false, 0);
//         pool.addToken(address(eth), false, 0);
//         //=====
//         orderManager = new OrderManager();
//         orderManager.setOracle(address(oracle));
//         orderManager.setPool(address(pool));

//         pool.setOrderManager(address(orderManager));
//         pool.setMaxLeverage(50);
//         //=====
//         vm.stopBroadcast();
//         vm.startBroadcast(address(reporter));
//         address[] memory addresses = new address[](2);
//         addresses[0] = address(btc);
//         addresses[1] = address(eth);

//         uint256[] memory prices = new uint256[](2);
//         prices[0] = 200 * 1e18;
//         prices[1] = 100 * 1e18;
//         oracle.postPrices(addresses, prices);
//         vm.stopBroadcast();

//         // linda add
//         vm.startBroadcast(linda);

//         vm.deal(linda, 10 * 1e18);
//         vm.deal(address(orderManager), 10 * 1e18);

//         btc.mint(1000 * 1e18);
//         btc.approve(address(pool), 1000 * 1e18);
//         vm.stopBroadcast();
//         pool.addLiquidity(address(btc), 100 * 1e18, 0, linda);

//         // alice add
//         vm.startBroadcast(alice);
//         vm.deal(alice, 1000 * 1e18);
//         eth.mint(100 * 1e18);
//         eth.approve(address(pool), 100 * 1e18);
//         vm.stopBroadcast();
//         pool.addLiquidity(address(eth), 100 * 1e18, 0, alice);
//     }

//     // function testRemoveLiquidity() public {
//     //     // alice remove
//     //     vm.startBroadcast(alice);
//     //     lp.approve(address(pool), lp.balanceOf(alice));
//     //     vm.stopBroadcast();
//     //     pool.removeLiquidity(address(eth), lp.balanceOf(alice), 0, alice);
//     //     console.log("balance alice", eth.balanceOf(alice));
//     // }

//     // function testSwap() public {
//     //     // mike swap
//     //     vm.startBroadcast(mike);
//     //     eth.mint(50 * 1e18);
//     //     eth.approve(address(pool), eth.balanceOf(mike));
//     //     vm.stopBroadcast();
//     //     pool.swap(address(eth), address(btc), 20 * 1e18, 0, address(mike));
//     //     console.log("balance btc mike", btc.balanceOf(mike));
//     // }

//     // function testLongPosition() public {
//     //     // mike swap
//     //     vm.startBroadcast(mike);
//     //     vm.roll(1);
//     //     eth.mint(50 * 1e18);
//     //     eth.approve(address(orderManager), eth.balanceOf(mike));
//     //     orderManager.placeOrder(
//     //         PositionType.INCREASE, Side.LONG, address(btc), address(eth), 10 * 1e18, 10e39, 200 * 1e18, OrderType.MARKET
//     //     );
//     //     vm.roll(2);
//     //     orderManager.executeOrder(1);
//     //     vm.stopBroadcast();

//     //     // change price
//     //     vm.startBroadcast(address(reporter));
//     //     address[] memory addresses = new address[](2);
//     //     addresses[0] = address(btc);
//     //     addresses[1] = address(eth);

//     //     uint256[] memory prices = new uint256[](2);
//     //     prices[0] = 220 * 1e18;
//     //     prices[1] = 100 * 1e18;
//     //     oracle.postPrices(addresses, prices);
//     //     vm.stopBroadcast();

//     //     // check profit
//     //     vm.startBroadcast(mike);
//     //     vm.roll(3);
//     //     orderManager.placeOrder(
//     //         PositionType.DECREASE, Side.LONG, address(btc), address(eth), 0, 10e39, 220 * 1e18, OrderType.MARKET
//     //     );
//     //     vm.roll(4);
//     //     orderManager.executeOrder(2);
//     //     vm.roll(5);
//     //     console.log("balance btc mike", btc.balanceOf(mike));
//     //     console.log("balance eth mike", eth.balanceOf(mike));
//     //     vm.stopBroadcast();
//     // }

//     function testCaseLiquidate() public {
//         // mike swap
//         vm.startBroadcast(mike);
//         vm.roll(1);
//         eth.mint(50 * 1e18);
//         eth.approve(address(orderManager), eth.balanceOf(mike));
//         orderManager.placeOrder(
//             PositionType.INCREASE, Side.LONG, address(btc), address(eth), 10 * 1e18, 10e39, 200 * 1e18, OrderType.MARKET
//         );
//         vm.roll(2);
//         orderManager.executeOrder(1);
//         vm.stopBroadcast();

//         // change price
//         vm.startBroadcast(address(reporter));
//         address[] memory addresses = new address[](2);
//         addresses[0] = address(btc);
//         addresses[1] = address(eth);

//         uint256[] memory prices = new uint256[](2);
//         prices[0] = 182 * 1e18;
//         prices[1] = 100 * 1e18;
//         oracle.postPrices(addresses, prices);
//         vm.stopBroadcast();

//         // check balance after liquidate
//         vm.roll(3);
//         vm.startBroadcast(deedee);
//         pool.liquidatePosition(address(mike), address(btc), address(eth), Side.LONG);
//         console.log("balance eth deedee", eth.balanceOf(deedee));
//         console.log("balance eth mike", eth.balanceOf(mike));
//         vm.stopBroadcast();
//     }
// }
