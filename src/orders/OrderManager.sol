// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {IPool, Side} from "../interfaces/IPool.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Test, console} from "forge-std/Test.sol";

// since we defined this function via a state variable of PoolStorage, it cannot be re-declared the interface IPool
interface IWhitelistedPool is IPool {
    function isAsset(address) external returns (bool);
}

enum OrderType {
    MARKET,
    LIMIT
}

enum PositionType {
    INCREASE,
    DECREASE
}

struct Order {
    address owner;
    address indexToken;
    address collateralToken;
    address payToken;
    uint256 collateral;
    uint256 sizeChange;
    uint256 expiresAt;
    uint256 submissionBlock;
    uint256 price;
    uint256 executionFee;
    Side side;
    PositionType positionType;
}

contract OrderManager is Ownable {
    using SafeERC20 for IERC20;

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;
    uint256 constant public MARKET_ORDER_TIMEOUT = 20 minutes;
    IWhitelistedPool public pool;
    IOracle public oracle;
    mapping(address => uint256[]) public userOrders;

    constructor() {
        nextOrderId = 1;
    }

    // ============= VIEW FUNCTIONS ==============

    function getOrders(address user, uint256 skip, uint256 take)
        external
        view
        returns (uint256[] memory orderIds, uint256 total)
    {
        total = userOrders[user].length;
        uint256 toIdx = skip + take;
        toIdx = toIdx > total ? total : toIdx;
        uint256 nOrders = toIdx > skip ? toIdx - skip : 0;
        orderIds = new uint[](nOrders);
        for (uint256 i = skip; i < skip + nOrders; i++) {
            orderIds[i] = userOrders[user][i];
        }
    }

    // =========== MUTATIVE FUNCTIONS ==========

    function placeOrder(
        PositionType _poisitionType,
        Side _side,
        address _indexToken,
        address _collateralToken,
        uint256 _collateral,
        uint256 _sizeChange,
        uint256 _price,
        OrderType _orderType
    ) external {
        require(pool.isAsset(_indexToken), "OrderManager:invalidTokens");
        if (_poisitionType == PositionType.INCREASE) {
            IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), _collateral);
        }
        uint256 orderId;
        Order memory order;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.collateral = _collateral;
        order.sizeChange = _sizeChange;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = 0;
        order.positionType = _poisitionType;
        order.side = _side;
        order.price = _price;
        orderId = nextOrderId;
        nextOrderId = orderId + 1;
        orders[orderId] = order;
        userOrders[msg.sender].push(orderId);
    }

    function executeOrder(uint256 _orderId) external {
        Order memory order = orders[_orderId];
        require(order.owner != address(0), "OrderManager:orderNotExists");
        require(block.number > order.submissionBlock, "OrderManager:blockNotPass");

        if (order.expiresAt != 0 && order.expiresAt < block.timestamp) {
            _expiresOrder(_orderId);
            return;
        }
        uint256 indexPrice = _getMarkPrice(order);
        bool isValid = order.side == Side.SHORT ? indexPrice >= order.price : indexPrice <= order.price;
        if (!isValid) {
            return;
        }
        _executeRequest(_orderId);
        delete orders[_orderId];
        emit OrderExecuted(_orderId, order, indexPrice);
    }

    // ============ Administrative =============

    function setOracle(address _oracle) external onlyOwner {
        require(_oracle != address(0), "OrderManager:invalidOracleAddress");
        oracle = IOracle(_oracle);
        emit OracleChanged(_oracle);
    }

    function setPool(address _pool) external onlyOwner {
        require(_pool != address(0), "OrderManager:invalidPoolAddress");
        require(address(pool) != _pool, "OrderManager:poolAlreadyAdded");
        pool = IWhitelistedPool(_pool);
        emit PoolSet(_pool);
    }

    // ========= INTERNAL FUCNTIONS ==========
    function _executeRequest(uint256 _orderId) internal {
        Order memory _order = orders[_orderId];
        if (_order.positionType == PositionType.INCREASE) {
            IERC20(_order.collateralToken).safeTransfer(address(pool), _order.collateral);
            pool.increasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _order.collateral,
                _order.sizeChange,
                _order.side
            );
        } else {
            IERC20 collateralToken = IERC20(_order.collateralToken);
            uint256 priorBalance = collateralToken.balanceOf(address(this));
            pool.decreasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _order.collateral,
                _order.sizeChange,
                _order.side,
                address(this)
            );

            uint256 payoutAmount = collateralToken.balanceOf(address(this)) - priorBalance;
            collateralToken.safeTransfer(_order.owner, payoutAmount);
        }
    }

    function _getMarkPrice(Order memory order) internal view returns (uint256) {
        return oracle.getPrice(order.indexToken);
    }

    function _expiresOrder(uint256 _orderId) internal {
        delete orders[_orderId];
        emit OrderExpired(_orderId);
    }

    event OracleChanged(address oracle);
    event PoolSet(address indexed pool);
    event OrderExpired(uint256 indexed key);
    event OrderExecuted(uint256 indexed key, Order order, uint256 fillPrice);
}
