// SPDX-License-Identifier: UNLICENSED

pragma solidity >=0.8.19;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {MathUtils} from "../lib/MathUtils.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {IPool, Side} from "../interfaces/IPool.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {SignedIntOps} from "../lib/SignedInt.sol";
import {Test, console} from "forge-std/Test.sol";

uint256 constant ORACLE_DECIMAL = 1e18;
uint256 constant LP_DECIMAL = 1e18;
uint256 constant PRECISION = 1e10;
uint256 constant INIT_LP = 100 * LP_DECIMAL;

struct AssetInfo {
    uint256 feeReserve;
    bool isStableCoin;
}

struct Position {
    uint256 size;
    uint256 collateralValue;
    uint256 reserveAmount;
    uint256 entryPrice;
}

struct IncreasePositionVars {
    uint256 reserveAdded;
    uint256 collateralAmount;
    uint256 collateralValueAdded;
    uint256 feeValue;
    uint256 daoFee;
    uint256 indexPrice;
    uint256 sizeChanged;
    uint256 feeAmount;
    uint256 totalLpFee;
}

struct DecreasePositionVars {
    uint256 collateralReduced;
    uint256 sizeChanged;
    uint256 indexPrice;
    uint256 collateralPrice;
    uint256 remainingCollateral;
    /// @notice reserve reduced due to reducion process
    uint256 reserveReduced;
    /// @notice total value of fee to be collect (include dao fee and LP fee)
    uint256 feeValue;
    /// @notice amount of collateral taken as fee
    uint256 daoFee;
    /// @notice real transfer out amount to user
    uint256 payout;
    /// @notice 'net' PnL (fee not counted)
    int256 pnl;
    int256 poolAmountReduced;
    uint256 totalLpFee;
}

struct Fee {
    uint256 swapFee;
    uint256 positionFee;
    uint256 liquidationFee;
    uint256 borrowFee;
}

contract Pool is Ownable, IPool {
    using SignedIntOps for int256;
    using SafeCast for uint256;

    /* =========== Statement  ======== */
    address public orderManager;
    Fee public fee;
    IOracle public oracle;
    mapping(address => AssetInfo) public poolAssets;
    address[] public allAssets;
    mapping(address => bool) public isAsset;
    ILPToken public lpToken;
    uint256 public maxLeverage;
    mapping(bytes32 => Position) public positions;

    /* =========== MODIFIERS ========== */
    constructor(address _oracle) {
        oracle = IOracle(_oracle);
        fee.liquidationFee = 5e3;
    }

    modifier onlyOrderManager() {
        _requireOrderManager();
        _;
    }

    modifier onlyAsset(address _token) {
        if (!isAsset[_token]) {
            revert AssetNotListed(_token);
        }
        _;
    }

    modifier sureEnoughBalance(address _token, uint256 _minAmount) {
        IERC20 token = IERC20(_token);
        if (token.balanceOf(address(this)) < _minAmount) {
            revert InsufficientPoolAmount(_token);
        }
        _;
    }

    // ========= View functions =========

    function getVirtualPoolValue() external view returns (uint256) {
        return _getPoolValue();
    }

    function calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        return _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
    }

    function calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount) external view returns (uint256 outAmount) {
        (outAmount) = _calcRemoveLiquidity(_tokenOut, _lpAmount);
    }

    // ============= Mutative functions =============
    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        onlyAsset(_token)
    {
        uint256 totalPoolValue = _getPoolValue();
        IERC20(_token).transferFrom(_to, address(this), _amountIn);
        uint256 priceToken = oracle.getPrice(_token);
        uint256 totalLP = lpToken.totalSupply();
        uint256 lpAmount;
        if (totalLP > 0) {
            lpAmount = _amountIn * priceToken * totalLP / totalPoolValue;
        } else {
            lpAmount = INIT_LP;
        }

        if (lpAmount < _minLpAmount) {
            revert SlippageExceeded();
        }
        lpToken.mint(_to, lpAmount);
        emit AddLiquidity(_to, _token, _amountIn);
    }

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _to)
        external
        sureEnoughBalance(_tokenOut, _minOut)
        onlyAsset(_tokenOut)
    {
        (uint256 outAmount) = _calcRemoveLiquidity(_tokenOut, _lpAmount);
        if (outAmount < _minOut) {
            revert SlippageExceeded();
        }
        lpToken.burnFrom(_to, _lpAmount);
        IERC20(_tokenOut).transfer(_to, outAmount);
        emit RemoveLiquidity(_to, outAmount);
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, address _to)
        external
        sureEnoughBalance(_tokenOut, _minOut)
        onlyAsset(_tokenOut)
        onlyAsset(_tokenIn)
    {
        IERC20 tokenOut = IERC20(_tokenOut);
        if (_tokenIn == _tokenOut) {
            revert SameTokenSwap(_tokenIn);
        }
        (uint256 amountOut) = _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
        if (amountOut < _minOut) {
            revert SlippageExceeded();
        }
        tokenOut.transfer(_to, amountOut);
        emit Swap(_to, _tokenIn, _tokenOut, _amountIn, amountOut, 0);
    }

    function increasePosition(
        address _account,
        address _indexToken,
        address _collateralToken,
        uint256 _collateral,
        uint256 _sizeChanged,
        Side _side
    ) external onlyAsset(_indexToken) onlyAsset(_collateralToken) onlyOrderManager {
        IncreasePositionVars memory vars;
        vars.collateralAmount = _collateral;
        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 collateralPrice = oracle.getPrice(_collateralToken);
        uint256 indexPrice = oracle.getPrice(_indexToken);
        vars.collateralValueAdded = collateralPrice * _collateral;
        vars.indexPrice = indexPrice;
        vars.sizeChanged = _sizeChanged;
        vars.reserveAdded = vars.sizeChanged / collateralPrice;

        position.entryPrice = PositionUtils.calcAveragePrice(
            _side, position.size, position.size + vars.sizeChanged, position.entryPrice, vars.indexPrice, 0
        );
        position.collateralValue =
            MathUtils.zeroCapSub(position.collateralValue + vars.collateralValueAdded, vars.feeValue);
        position.size += vars.sizeChanged;
        position.reserveAmount += vars.reserveAdded;

        _validatePosition(position, true);
        positions[key] = position;
    }

    function decreasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralChanged,
        uint256 _sizeChanged,
        Side _side,
        address _receiver
    ) external onlyAsset(_indexToken) onlyAsset(_collateralToken) onlyOrderManager {
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];

        if (position.size == 0) {
            revert PositionNotExists(_owner, _indexToken, _collateralToken, _side);
        }

        DecreasePositionVars memory vars =
            _calcDecreasePayout(position, _indexToken, _collateralToken, _side, _sizeChanged, _collateralChanged, false);

        // reset to actual reduced value instead of user input
        vars.collateralReduced = position.collateralValue - vars.remainingCollateral;
        position.size = position.size - vars.sizeChanged;
        position.reserveAmount = position.reserveAmount - vars.reserveReduced;
        position.collateralValue = vars.remainingCollateral;

        _validatePosition(position, false);
        if (position.size == 0) {
            delete positions[key];
        } else {
            positions[key] = position;
        }

        IERC20(_collateralToken).transfer(_receiver, vars.payout);
    }

    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side)
        external
        onlyAsset(_indexToken)
        onlyAsset(_collateralToken)
    {
        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        // uint256 markPrice = oracle.getPrice(_indexToken);
        // if (!_liquidatePositionAllowed(position, _side, markPrice)) {
        //     revert PositionNotLiquidated(key);
        // }
        DecreasePositionVars memory vars = _calcDecreasePayout(
            position, _indexToken, _collateralToken, _side, position.size, position.collateralValue, true
        );

        // ...emit
        delete positions[key];
        _doTransferOut(_collateralToken, _account, vars.payout);
        _doTransferOut(_collateralToken, msg.sender, fee.liquidationFee / vars.collateralPrice);
    }

    // ========= Admin functions ========

    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        _setMaxLeverage(_maxLeverage);
    }

    function setFee(Fee memory _fee) external onlyOwner {
        fee = _fee;
    }

    function setLpToken(address _lp) external onlyOwner {
        lpToken = ILPToken(_lp);
    }

    function addToken(address _token, bool _isStableCoin, uint256 _feeReserve) external onlyOwner {
        _requireAddress(_token);
        AssetInfo memory assetInfo;
        assetInfo.isStableCoin = _isStableCoin;
        assetInfo.feeReserve = _feeReserve;
        poolAssets[_token] = assetInfo;
        allAssets.push(_token);
        isAsset[_token] = true;
        emit AddPoolToken(_token);
    }

    function changeOracle(address _oracle) external onlyOwner {
        _requireAddress(_oracle);
        IOracle oldOracle = IOracle(address(oracle));
        oracle = IOracle(_oracle);
        emit OracleChange(address(oldOracle), address(oracle));
    }

    function setOrderManager(address _orderManager) external onlyOwner {
        _requireAddress(_orderManager);
        orderManager = _orderManager;
        emit SetOrderManager(_orderManager);
    }

    // ======== Internal functions =========

    function _getPoolValue() internal view returns (uint256 sum) {
        uint256[] memory prices = _getAllPrices();
        for (uint256 i = 0; i < allAssets.length;) {
            address token = allAssets[i];
            IERC20 _token = IERC20(token);
            assert(isAsset[token]); // double check
            uint256 price = prices[i];
            sum = sum + uint256(price * _token.balanceOf(address(this)));
            unchecked {
                ++i;
            }
        }
    }

    function _getAllPrices() internal view returns (uint256[] memory) {
        return oracle.getMultiplePrices(allAssets);
    }

    function _getPrice(address _token) internal view returns (uint256) {
        return oracle.getPrice(_token);
    }

    function _calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        internal
        view
        returns (uint256 amountOut)
    {
        uint256 priceIn = _getPrice(_tokenIn);
        uint256 priceOut = _getPrice(_tokenOut);
        uint256 valueChange = _amountIn * priceIn;
        amountOut = valueChange / priceOut;
    }

    function _calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount) internal view returns (uint256 outAmount) {
        uint256 priceToken = _getPrice(_tokenOut);
        uint256 poolValue = _getPoolValue();
        uint256 totalLp = lpToken.totalSupply();
        outAmount = (_lpAmount * poolValue) / totalLp / priceToken;
    }

    function _setMaxLeverage(uint256 _maxLeverage) internal {
        if (_maxLeverage == 0) {
            revert InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        emit MaxLeverageChanged(_maxLeverage);
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
    }

    function _requireAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert ZeroAddress();
        }
    }

    function _requireOrderManager() internal view {
        if (msg.sender != orderManager) {
            revert OrderManagerOnly();
        }
    }

    function _validatePosition(Position memory _position, bool _isIncrease) internal view {
        if ((_isIncrease && _position.size == 0)) {
            revert InvalidPositionSize();
        }

        if (_position.size < _position.collateralValue || _position.size > _position.collateralValue * maxLeverage) {
            revert InvalidLeverage(_position.size, _position.collateralValue, maxLeverage);
        }
    }

    // need refactor
    function _calcDecreasePayout(
        Position memory _position,
        address _indexToken,
        address _collateralToken,
        Side _side,
        uint256 _sizeChanged,
        uint256 _collateralChanged,
        bool isLiquidate
    ) internal view returns (DecreasePositionVars memory vars) {
        // clean user input
        vars.sizeChanged = MathUtils.min(_position.size, _sizeChanged);
        vars.collateralReduced = _position.collateralValue < _collateralChanged || _position.size == vars.sizeChanged
            ? _position.collateralValue
            : _collateralChanged;

        vars.indexPrice = oracle.getPrice(_indexToken);
        vars.collateralPrice = oracle.getPrice(_collateralToken);

        // vars is santinized, only trust these value from now on
        vars.reserveReduced = (_position.reserveAmount * vars.sizeChanged) / _position.size;
        vars.pnl = PositionUtils.calcPnl(_side, vars.sizeChanged, _position.entryPrice, vars.indexPrice);

        // first try to deduct fee and lost (if any) from withdrawn collateral
        int256 payoutValue = vars.pnl + vars.collateralReduced.toInt256() - vars.feeValue.toInt256();
        if (isLiquidate) {
            payoutValue = payoutValue - fee.liquidationFee.toInt256();
        }
        int256 remainingCollateral = (_position.collateralValue - vars.collateralReduced).toInt256(); // subtraction never overflow, checked above
        // if the deduction is too much, try to deduct from remaining collateral
        if (payoutValue < 0) {
            remainingCollateral = remainingCollateral + payoutValue;
            payoutValue = 0;
        }
        int256 collateralPrice = vars.collateralPrice.toInt256();
        vars.payout = uint256(payoutValue / collateralPrice);
        int256 poolValueReduced = vars.pnl;
        if (remainingCollateral < 0) {
            if (!isLiquidate) {
                revert UpdateCauseLiquidation();
            }
            // if liquidate too slow, pool must take the lost
            poolValueReduced = poolValueReduced - remainingCollateral;
            vars.remainingCollateral = 0;
        } else {
            vars.remainingCollateral = uint256(remainingCollateral);
        }

        if (_side == Side.LONG) {
            poolValueReduced = poolValueReduced + vars.collateralReduced.toInt256();
        } else if (poolValueReduced < 0) {
            // in case of SHORT, trader can lost unlimited value but pool can only increase at most collateralValue - liquidationFee
            poolValueReduced = poolValueReduced.cap(
                MathUtils.zeroCapSub(_position.collateralValue, vars.feeValue + fee.liquidationFee)
            );
        }
        vars.poolAmountReduced = poolValueReduced / collateralPrice;
    }

    function _liquidatePositionAllowed(Position memory _position, Side _side, uint256 _indexPrice)
        internal
        view
        returns (bool)
    {
        if (_position.size == 0) {
            return false;
        }
        // calculate fee needed when close position
        uint256 feeValue = _calcPositionFee();
        int256 pnl = PositionUtils.calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        int256 collateral = pnl + _position.collateralValue.toInt256();

        // liquidation occur when collateral cannot cover margin fee
        return collateral < 0 || uint256(collateral) < (feeValue + fee.liquidationFee);
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount != 0) {
            IERC20 token = IERC20(_token);
            token.transfer(_to, _amount);
        }
    }

    function _calcPositionFee() internal pure returns (uint256 feeValue) {
        uint256 borrowFee = 0;
        uint256 positionFee = 0;
        feeValue = borrowFee + positionFee;
    }

    // ========= Event ===============

    event AddPoolToken(address token);
    event SetOrderManager(address manager);
    event OracleChange(address oldOracle, address newOracle);
    event MaxLeverageChanged(uint256 levarage);
    event AddLiquidity(address wallet, address asset, uint256 amount);
    event RemoveLiquidity(address wallet, uint256 amount);
    event Swap(
        address indexed sender, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, uint256 fee
    );

    // ========= Error ===============
    error AssetNotListed(address token);
    error InsufficientPoolAmount(address token);
    error ZeroAddress();
    error SameTokenSwap(address token);
    error SlippageExceeded();
    error OrderManagerOnly();
    error InvalidMaxLeverage();
    error InvalidPositionSize();
    error InvalidLeverage(uint256 size, uint256 margin, uint256 maxLeverage);
    error PositionNotExists(address owner, address indexToken, address collateralToken, Side side);
    error UpdateCauseLiquidation();
    error ZeroAmount();
    error PositionNotLiquidated(bytes32 key);
}
