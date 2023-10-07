// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {Oracle, TokenConfig} from "../src/oracle/Oracle.sol";
import {Pool, Fee, TokenWeight} from "../src/pool/Pool.sol";
import {LPToken} from "../src/tokens/LPToken.sol";
import {WETH9} from "../src/helper/WETH9.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Router} from "../src/pool/Router.sol";
import {OrderManager} from "../src/orders/OrderManager.sol";
import {PositionType, OrderType} from "../src/orders/OrderManager.sol";
import {Side} from "../src/interfaces/IPool.sol";

contract Poolz is Test {
    Oracle public oracle;
    Pool public pool;
    Router public router;
    OrderManager public orderManager;

    LPToken public lp;
    MockERC20 public btc;
    MockERC20 public eth;
    MockERC20 public usdc;
    WETH9 public weth;

    address public constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    address public deployper = vm.addr(1);
    address public lper = vm.addr(2);
    address public mike = vm.addr(3);

    function setUp() public {
        vm.startBroadcast(address(deployper));

        eth = new MockERC20("ETH", "ETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        btc = new MockERC20("BTC", "BTC", 8);
        weth = new WETH9();
        oracle = new Oracle();
        oracle.addReporter(deployper);
        oracle.configToken(address(btc), 8, 8);
        oracle.configToken(address(eth), 18, 8);
        oracle.configToken(address(weth), 18, 8);
        oracle.configToken(address(usdc), 6, 8);
        pool = new Pool(address(oracle),1000000,3600);
        lp = new LPToken("LP","LP",address(pool));
        pool.setLpToken(address(lp));
        pool.addToken(address(btc), false);
        pool.addToken(address(eth), false);
        pool.addToken(address(weth), false);
        pool.addToken(address(usdc), true);
        TokenWeight[] memory tokenWeight = new TokenWeight[](4);
        tokenWeight[0] = TokenWeight(address(eth), 200);
        tokenWeight[1] = TokenWeight(address(btc), 200);
        tokenWeight[2] = TokenWeight(address(usdc), 500);
        tokenWeight[3] = TokenWeight(address(weth), 100);
        pool.setTargetWeight(tokenWeight);
        router = new Router(address(pool),address(weth),address(lp));
        //=====
        orderManager = new OrderManager(address(oracle),address(pool), 1e16 );
        pool.setOrderManager(address(orderManager));
        pool.setMaxLeverage(50);
        Fee memory fee =
            Fee(25000000, 20000000, 40000000, 10000000, 50000000, 1000000000, 5000000000000000000000000000000, 10000000);
        pool.setFee(fee);

        address[] memory addresses = new address[](4);
        addresses[0] = address(btc);
        addresses[1] = address(eth);
        addresses[2] = address(weth);
        addresses[3] = address(usdc);

        uint256[] memory prices = new uint256[](4);
        prices[0] = 25_000e8;
        prices[1] = 1700e8;
        prices[2] = 220e8;
        prices[3] = 1e8;
        oracle.postPrices(addresses, prices);
        vm.stopBroadcast();
    }

    function addLiquidity() public {
        vm.startBroadcast(lper);
        eth.mint(1000e18);
        eth.approve(address(router), type(uint256).max);
        btc.mint(1000e18);
        btc.approve(address(router), type(uint256).max);
        usdc.mint(1000e18);
        usdc.approve(address(router), type(uint256).max);
        router.addLiquidity(address(eth), 1000e18, 0);
        router.addLiquidity(address(btc), 1000e18, 0);
        router.addLiquidity(address(usdc), 1000e18, 0);
        vm.deal(lper, 1000e18);
        router.addLiquidity{value: 1000e18}(ETH, 1000e18, 0);
        uint256 vault = pool.getPoolValue();
        console.log("vault :", vault);
        vm.stopBroadcast();
    }

    function priceChange(uint256 _btcPrice, uint256 _ethPrice, uint256 _bnbPrice, uint256 _usdcPrice) public {
        // change price
        vm.startBroadcast(address(deployper));
        address[] memory addresses = new address[](4);
        addresses[0] = address(btc);
        addresses[1] = address(eth);
        addresses[2] = address(weth);
        addresses[3] = address(usdc);

        uint256[] memory prices = new uint256[](4);
        prices[0] = _btcPrice;
        prices[1] = _ethPrice;
        prices[2] = _bnbPrice;
        prices[3] = _usdcPrice;
        oracle.postPrices(addresses, prices);
        vm.stopBroadcast();
    }

    function executeOrderByReposter(uint256 id) public {
        vm.startBroadcast(address(deployper));
        orderManager.executeOrder(id, payable(address(deployper)));
        vm.stopBroadcast();
    }

    function monitorBalance() public {
        console.log("==== Monitor Balance ====");
        console.log("balance btc :", btc.balanceOf(mike));
        console.log("balance eth :", eth.balanceOf(mike));
        console.log("balance bnb :", mike.balance);
        console.log("balance usdc :", usdc.balanceOf(mike));
    }

    function testLongPosition() public {
        addLiquidity();
        // console.log("balance usdc orderManager:", usdc.balanceOf(address(orderManager)));
        // console.log("balance usdc pool :", usdc.balanceOf(address(pool)));
        // mike
        vm.startBroadcast(mike);
        vm.roll(1);
        usdc.mint(50 * 1e6);
        vm.deal(mike, 1e18);
        usdc.approve(address(orderManager), usdc.balanceOf(mike));

        monitorBalance();

        orderManager.placeOrder{value: 1e16}(
            PositionType.INCREASE, Side.LONG, address(btc), address(usdc), 50e6, 100e30, 25_000e8, OrderType.MARKET
        );
        vm.stopBroadcast();
        vm.roll(2);
        executeOrderByReposter(1);
        vm.roll(3);
        priceChange(14_500e8, 1700e8, 220e8, 1e8);

        vm.roll(4);
        vm.startBroadcast(mike);
        orderManager.placeOrder{value: 1e16}(
            PositionType.DECREASE, Side.LONG, address(btc), address(usdc), 50e6, 100e30, 0, OrderType.MARKET
        );
        vm.stopBroadcast();

        vm.roll(5);
        executeOrderByReposter(2);

        vm.roll(6);
        monitorBalance();
        // console.log("balance usdc orderManager:", usdc.balanceOf(address(orderManager)));
        // console.log("balance usdc pool :", usdc.balanceOf(address(pool)));
    }

    function testLiquidationPosition() public {
        addLiquidity();

        // mike
        vm.startBroadcast(mike);
        vm.roll(1);
        usdc.mint(50 * 1e6);
        vm.deal(mike, 1e18);
        usdc.approve(address(orderManager), usdc.balanceOf(mike));

        monitorBalance();

        orderManager.placeOrder{value: 1e16}(
            PositionType.INCREASE, Side.LONG, address(btc), address(usdc), 50e6, 100e30, 25_000e8, OrderType.MARKET
        );
        vm.stopBroadcast();
        vm.roll(2);
        executeOrderByReposter(1);
        vm.roll(3);
        priceChange(13_600e8, 1700e8, 220e8, 1e8);

        vm.roll(4);

        vm.startBroadcast(address(deployper));
        uint256 a = usdc.balanceOf(address(deployper));
        pool.liquidatePosition(mike, address(btc), address(usdc), Side.LONG);
        console.log("balance usdc deployper earn:", usdc.balanceOf(address(deployper)) - a);
        vm.stopBroadcast();
        monitorBalance();
    }

    // function testRemoveLiquidity() public {
    //     addLiquidity();
    //     // alice remove
    //     vm.startBroadcast(alice);
    //     lp.approve(address(router), lp.balanceOf(alice));
    //     console.log("balance lp alice", lp.balanceOf(alice));
    //     console.log("balance alice", eth.balanceOf(alice));
    //     router.removeLiquidity(address(eth), lp.balanceOf(alice), 0);
    //     console.log("balance alice", eth.balanceOf(alice));
    //     vm.stopBroadcast();
    //     uint256 vault = pool.getPoolValue();
    //     console.log("vault :", vault);
    // }

    // function testRemoveLiquidityBnb() public {
    //     addLiquidity();
    //     // MIKE remove
    //     vm.startBroadcast(mike);
    //     lp.approve(address(router), lp.balanceOf(mike));
    //     router.removeLiquidity(ETH, lp.balanceOf(mike), 0);
    //     console.log("balance mike", mike.balance);
    // }

    // // eth - > erc20
    // function testSwapBnb() public {
    //     addLiquidity();
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     vm.deal(mike, 1e18);
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     router.swap{value: 1e18}(ETH, address(eth), 1e8, 0);
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     console.log("rs need = 220/1700 ");
    //     vm.stopBroadcast();
    // }

    // //erc20 -> eth
    // function testSwapBnbRe() public {
    //     addLiquidity();
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     btc.mint(1e4);
    //     btc.approve(address(router), btc.balanceOf(mike));
    //     console.log("balance bnb mike", mike.balance);
    //     router.swap(address(btc), ETH, 1e4, 0); // 0.01 btc
    //     console.log("balance eth mike", mike.balance);
    //     console.log("rs need = 250/220/100 ");
    //     vm.stopBroadcast();
    // }

    // function testSwap() public {
    //     addLiquidity();
    //     // mike swap
    //     vm.startBroadcast(mike);
    //     btc.mint(50e8);
    //     btc.approve(address(router), btc.balanceOf(mike));
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     router.swap(address(btc), address(eth), 1e8, 0);
    //     console.log("balance eth mike", eth.balanceOf(mike));
    //     console.log("rs need = 2500/1700 ");
    //     vm.stopBroadcast();
    // }
}
