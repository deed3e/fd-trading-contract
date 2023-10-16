// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {IPool, Side} from "../interfaces/IPool.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Ownable} from "openzeppelin/access/Ownable.sol";
import {Test, console} from "forge-std/Test.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {console} from "forge-std/Test.sol";

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
    uint256 collateralAmount;
    uint256 sizeChange;
    uint256 expiresAt;
    uint256 submissionBlock;
    uint256 price;
    uint256 executionFee;
    Side side;
    PositionType positionType;
    OrderType orderType;
}

contract OrderManager is Ownable {
    using SafeERC20 for IERC20;

    address private constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 public constant MARKET_ORDER_TIMEOUT = 5 minutes;

    uint256 public nextOrderId;
    uint256 public minExecutionFee;
    mapping(uint256 => Order) public orders;
    mapping(address => uint256[]) public userOrders;
    IWhitelistedPool public pool;
    IOracle public oracle;
    IWETH public weth;

    constructor(address _oracle, address _pool, uint256 _minExecutionFee) {
        nextOrderId = 1;
        oracle = IOracle(_oracle);
        pool = IWhitelistedPool(_pool);
        minExecutionFee = _minExecutionFee;
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
        uint256 _collateralAmount,
        uint256 _sizeChange,
        uint256 _price,
        OrderType _orderType
    ) external payable {
        require(pool.isAsset(_indexToken) && pool.isAsset(_collateralToken), "OrderManager:invalidTokens");
        address payToken;
        (payToken, _collateralToken) =
            _collateralToken == ETH ? (ETH, address(weth)) : (_collateralToken, _collateralToken);
        if (_poisitionType == PositionType.INCREASE) {
            if (payToken == ETH) {
                weth.deposit{value: _collateralAmount}();
            } else {
                IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), _collateralAmount);
            }
        }
        uint256 orderId;
        Order memory order;
        order.owner = msg.sender;
        order.indexToken = _indexToken;
        order.collateralToken = _collateralToken;
        order.collateralAmount = _collateralAmount;
        order.sizeChange = _sizeChange;
        order.expiresAt = _orderType == OrderType.MARKET ? block.timestamp + MARKET_ORDER_TIMEOUT : 0;
        order.submissionBlock = block.number;
        order.executionFee = msg.value;
        require(order.executionFee >= minExecutionFee, "OrderManager:executionFeeTooLow");

        order.orderType = _orderType;
        order.positionType = _poisitionType;
        order.side = _side;
        order.price = _price;
        orderId = nextOrderId;
        orders[orderId] = order;

        userOrders[msg.sender].push(orderId);
        nextOrderId = orderId + 1;
        emit OrderPlaced(orderId, order);
    }

    function executeOrder(uint256 _orderId) external {
        Order memory order = orders[_orderId];
        require(block.number > order.submissionBlock, "OrderManager:blockNotPass");
        require(order.owner != address(0), "OrderManager:orderNotExists");
        if (order.expiresAt != 0 && order.expiresAt < block.timestamp) {
            _expiresOrder(_orderId);
            return;
        }
        uint256 indexPrice = oracle.getPrice(order.indexToken);
        bool isValidPrice = order.orderType == OrderType.LIMIT
            ? order.side == Side.LONG ? indexPrice <= order.price : indexPrice >= order.price
            : true;   
        if (!isValidPrice) {
            return;
        }
        _executeRequest(_orderId);
        delete orders[_orderId];
        _safeTransferETH(msg.sender, order.executionFee);
        emit OrderExecuted(_orderId, order, indexPrice);
    }

    // ========= INTERNAL FUCNTIONS ==========
    function _executeRequest(uint256 _orderId) internal {
        Order memory _order = orders[_orderId];
        if (_order.positionType == PositionType.INCREASE) {
            IERC20(_order.collateralToken).safeTransfer(address(pool), _order.collateralAmount);
            pool.increasePosition(
                _order.owner,
                _order.indexToken,
                _order.collateralToken,
                _order.collateralAmount,
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
                _order.collateralAmount,
                _order.sizeChange,
                _order.side,
                address(this)
            );

            uint256 payoutAmount = collateralToken.balanceOf(address(this)) - priorBalance;

            if (_order.collateralToken == ETH) {
                _safeTransferETH(_order.owner, payoutAmount);
            } else {
                collateralToken.safeTransfer(_order.owner, payoutAmount);
            }
        }
    }

    function _expiresOrder(uint256 _orderId) internal {
        delete orders[_orderId];
        emit OrderExpired(_orderId);
        Order memory order = orders[_orderId];

        // refund fee
        _safeTransferETH(order.owner, order.executionFee);

        // refund collateral
        if (order.positionType == PositionType.INCREASE) {
            address refundToken = order.collateralToken;
            _refundCollateral(refundToken, order.collateralAmount, order.owner);
        }
    }

    function _safeTransferETH(address to, uint256 amount) internal {
        // solhint-disable-next-line avoid-low-level-calls
        (bool success,) = to.call{value: amount}(new bytes(0));
        require(success, "TransferHelper: ETH_TRANSFER_FAILED");
    }

    function _refundCollateral(address _refundToken, uint256 _amount, address _orderOwner) internal {
        if (_refundToken == address(weth) || _refundToken == ETH) {
            _safeTransferETH(_orderOwner, _amount);
        } else {
            IERC20(_refundToken).safeTransfer(_orderOwner, _amount);
        }
    }

    event OrderExpired(uint256 indexed key);
    event OrderExecuted(uint256 indexed key, Order order, uint256 fillPrice);
    event OrderPlaced(uint256 indexed key, Order order);
}
