// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.19;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IERC20} from "openzeppelin/interfaces/IERC20.sol";
import {MathUtils} from "../lib/MathUtils.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {ILPToken} from "../interfaces/ILPToken.sol";
import {SafeCast} from "openzeppelin/utils/math/SafeCast.sol";
import {SignedInt, SignedIntOps} from "../lib/SignedInt.sol";
import {IPool} from "../interfaces/IPool.sol";
import {PositionUtils} from "../lib/PositionUtils.sol";
import {Side} from "../interfaces/IPool.sol";

import {console} from "forge-std/Test.sol";

uint256 constant PRECISION = 1e10;
uint256 constant LP_INITIAL_PRICE = 1e12; //fix to 1$
uint256 constant MAX_BASE_SWAP_FEE = 1e8; // 1%
uint256 constant MAX_ASSETS = 10;
uint256 constant TIME_OUT_ORACLE = 1 minutes;

struct TokenWeight {
    address token;
    uint256 weight;
}

struct AssetInfo {
    uint256 feeReserve;
    uint256 borrowIndex;
    uint256 lastAccrualTimestamp;
    /// @notice amount of token deposited (via add liquidity or increase long position)
    uint256 poolAmount;
    /// @notice amount of token reserved for paying out when user decrease long position
    uint256 reservedAmount;
    /// @notice total borrowed (in USD) to leverage
    uint256 guaranteedValue;
    /// @notice total size of all short positions
    uint256 totalShortSize;
}

enum DecreaseType {
    UPDATE,
    CLOSE
}

struct Position {
    uint256 size;
    uint256 collateralValue;
    uint256 reserveAmount;
    uint256 entryPrice;
    uint256 borrowIndex;
}

struct Fee {
    uint256 baseSwapFee;
    uint256 baseAddRemoveLiquidityFee;
    uint256 taxBasisPoint;
    uint256 stableCoinBaseSwapFee;
    uint256 stableCoinTaxBasisPoint;
    uint256 daoFee;
    uint256 liquidationFee;
    uint256 positionFee;
}

contract Pool is Ownable, IPool {
    using SignedIntOps for int256;
    using SafeCast for uint256;

    /* =========== Statement  ======== */
    Fee public fee;
    IOracle public oracle;
    address[] public allAssets;
    mapping(address => AssetInfo) public poolAssets;
    mapping(address => bool) public isAsset;
    mapping(address => bool) public isStableCoin;
    mapping(address => uint256) public targetWeights;
    ILPToken public lpToken;
    uint256 public totalWeight;

    address public orderManager;
    uint256 public maxLeverage;

    uint256 public interestRate;
    uint256 public accrualInterval;
    mapping(bytes32 => Position) public positions;

    /* =========== MODIFIERS ========== */
    constructor(address _oracle, uint256 _interestRate, uint256 _accrualInterval) {
        oracle = IOracle(_oracle);
        fee.liquidationFee = 5e3;
        interestRate = _interestRate;
        accrualInterval = _accrualInterval;
    }

    modifier onlyAsset(address _token) {
        if (!isAsset[_token]) {
            revert NotAsset(_token);
        }
        _;
    }

    modifier sureEnoughBalance(address _token, uint256 _minAmount) {
        IERC20 token = IERC20(_token);
        if (token.balanceOf(address(this)) - poolAssets[_token].feeReserve < _minAmount) {
            revert InsufficientPoolAmount(_token);
        }
        _;
    }

    modifier onlyOrderManager() {
        _requireOrderManager();
        _;
    }

    // ========= View functions =========

    function getPoolValue() external view returns (uint256) {
        return _getPoolValue();
    }

    function calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        external
        view
        returns (uint256 amountOutAfterFee, uint256 feeAmount)
    {
        return _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
    }

    function calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount) external view returns (uint256 outAmount) {
        (outAmount) = _calcRemoveLiquidity(_tokenOut, _lpAmount);
    }

    function calcAddLiquidity(address _tokenIn, uint256 _amount)
        external
        view
        returns (uint256 outAmount, uint256 feeAmount)
    {
        uint256 markPrice = _getPrice(_tokenIn);
        (outAmount, feeAmount) = _calcAddLiquidity(_tokenIn, _amount, markPrice);
    }

    // ============= Mutative functions =============
    function addLiquidity(address _token, uint256 _amountIn, uint256 _minLpAmount, address _to)
        external
        onlyAsset(_token)
    {
        IERC20(_token).transferFrom(msg.sender, address(this), _amountIn);
        _accrueInterest(_token);
        uint256 markPrice = _getPrice(_token);
        (uint256 lpAmount, uint256 _feeAmount) = _calcAddLiquidity(_token, _amountIn, markPrice);
        (uint256 daoFee,) = _calcDaoFee(_feeAmount);
        poolAssets[_token].feeReserve += daoFee;
        if (lpAmount < _minLpAmount) {
            revert SlippageExceeded();
        }
        lpToken.mint(_to, lpAmount);
        emit AddLiquidity(_to, _token, _amountIn, _feeAmount, markPrice);
    }

    function removeLiquidity(address _tokenOut, uint256 _lpAmount, uint256 _minOut, address _wallet)
        external
        sureEnoughBalance(_tokenOut, _minOut)
        onlyAsset(_tokenOut)
    {
        _accrueInterest(_tokenOut);
        (uint256 outAmount) = _calcRemoveLiquidity(_tokenOut, _lpAmount);
        uint256 markPrice = _getPrice(_tokenOut);
        if (outAmount < _minOut) {
            revert SlippageExceeded();
        }
        lpToken.burnFrom(msg.sender, _lpAmount);
        _doTransferOut(_tokenOut, _wallet, outAmount);
        emit RemoveLiquidity(_wallet, _tokenOut, outAmount, markPrice);
    }

    function swap(address _tokenIn, address _tokenOut, uint256 _amountIn, uint256 _minOut, address _to)
        external
        sureEnoughBalance(_tokenOut, _minOut)
        onlyAsset(_tokenOut)
    {
        if (_tokenIn == _tokenOut) {
            revert SameTokenSwap(_tokenIn);
        }
        _accrueInterest(_tokenIn);
        _accrueInterest(_tokenOut);
        uint256 markPriceIn = _getPrice(_tokenIn);
        (uint256 amountOut, uint256 swapFee) = _calcSwapOutput(_tokenIn, _tokenOut, _amountIn);
        (uint256 daoFee,) = _calcDaoFee(swapFee);
        poolAssets[_tokenIn].feeReserve += daoFee;
        if (amountOut < _minOut) {
            revert SlippageExceeded();
        }
        _doTransferOut(_tokenOut, _to, amountOut);
        emit Swap(_to, _tokenIn, _tokenOut, _amountIn, amountOut, swapFee, markPriceIn);
    }

    function increasePosition(
        address _owner,
        address _indexToken,
        address _collateralToken,
        uint256 _collateralAmount,
        uint256 _sizeChanged,
        Side _side
    ) external onlyAsset(_indexToken) onlyAsset(_collateralToken) onlyOrderManager {
        bytes32 key = _getPositionKey(_owner, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 collateralPrice = oracle.getPrice(_collateralToken);
        uint256 indexPrice = oracle.getPrice(_indexToken);
        uint256 reserveAdded = _sizeChanged / collateralPrice;
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        uint256 feeValue = _calcPositionFee(position, _sizeChanged, borrowIndex);

        position.entryPrice = PositionUtils.calcAveragePrice(
            _side, position.size, position.size + _sizeChanged, position.entryPrice, indexPrice, 0
        );
        position.collateralValue = MathUtils.zeroCapSub(
            position.collateralValue + (collateralPrice * _collateralAmount),
            _calcPositionFee(position, _sizeChanged, borrowIndex)
        );
        position.size += _sizeChanged;
        position.reserveAmount += reserveAdded;

        _validatePosition(position, true);
        positions[key] = position;

        emit IncreasePosition(
            key, _owner, _collateralToken, _indexToken, _collateralAmount, _sizeChanged, _side, indexPrice, feeValue
        );
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
       _accrueInterest(_collateralToken);
        if (position.size == 0) {
            revert PositionNotExists(_owner, _indexToken, _collateralToken, _side);
        }

        uint256 sizeChanged = _sizeChanged > position.size ? position.size : _sizeChanged;
        (
            uint256 payoutAmount,
            uint256 collateralReduced,
            int256 remainingCollateral,
            uint256 reserveReduced,
            uint256 indexPrice,
            int256 pnl,
            uint256 feeValue
        ) = _calcDecreasePayout(position, _indexToken, _collateralToken, _side, sizeChanged, _collateralChanged, false);
        collateralReduced = position.collateralValue - uint256(remainingCollateral);
        position.size = position.size - sizeChanged;
        position.reserveAmount = position.reserveAmount - reserveReduced;
        position.collateralValue = uint256(remainingCollateral);
        console.log("feeValue", feeValue);
        _validatePosition(position, false);
        if (position.size == 0) {
            emit DecreasePosition(
                key,
                _owner,
                _collateralToken,
                _indexToken,
                collateralReduced,
                sizeChanged,
                _side,
                indexPrice,
                pnl.asTuple(),
                feeValue,
                DecreaseType.CLOSE
            );
            delete positions[key];
        } else {
            emit DecreasePosition(
                key,
                _owner,
                _collateralToken,
                _indexToken,
                collateralReduced,
                sizeChanged,
                _side,
                indexPrice,
                pnl.asTuple(),
                feeValue,
                DecreaseType.UPDATE
            );
            positions[key] = position;
        }
        IERC20(_collateralToken).transfer(_receiver, payoutAmount);
    }

    function liquidatePosition(address _account, address _indexToken, address _collateralToken, Side _side)
        external
        onlyAsset(_indexToken)
        onlyAsset(_collateralToken)
    {
        bytes32 key = _getPositionKey(_account, _indexToken, _collateralToken, _side);
        Position memory position = positions[key];
        uint256 markPrice = oracle.getPrice(_indexToken);
        uint256 borrowIndex = _accrueInterest(_collateralToken);
        if (!_liquidatePositionAllowed(position, _side, markPrice, borrowIndex)) {
            revert PositionNotLiquidated(key);
        }
        (uint256 payoutAmount,,,,,,) = _calcDecreasePayout(
            position, _indexToken, _collateralToken, _side, position.size, position.collateralValue, true
        );

        uint256 collateralPrice = _getPrice(_collateralToken);
        delete positions[key];
        _doTransferOut(_collateralToken, _account, payoutAmount);
        _doTransferOut(_collateralToken, msg.sender, fee.liquidationFee / collateralPrice);
    }

    // ========= Admin functions ========

    function setOrderManager(address _orderManager) external onlyOwner {
        _requireAddress(_orderManager);
        orderManager = _orderManager;
    }

    function setFee(Fee memory _fee) external onlyOwner {
        fee = _fee;
    }

    function setLpToken(address _lp) external onlyOwner {
        lpToken = ILPToken(_lp);
    }

    function addToken(address _token, bool _isStableCoin) external onlyOwner {
        if (isAsset[_token]) {
            revert DuplicateToken(_token);
        }
        uint256 nAssets = allAssets.length;
        if (nAssets + 1 > MAX_ASSETS) {
            revert TooManyTokenAdded(nAssets, MAX_ASSETS);
        }
        _requireAddress(_token);
        AssetInfo memory assetInfo;
        poolAssets[_token] = assetInfo;
        allAssets.push(_token);
        isAsset[_token] = true;
        isStableCoin[_token] = _isStableCoin;
        emit AddPoolToken(_token);
    }

    function setTargetWeight(TokenWeight[] memory tokens) external onlyOwner {
        uint256 nTokens = tokens.length;
        if (nTokens != allAssets.length) {
            revert RequireAllTokens();
        }
        uint256 total;
        for (uint256 i = 0; i < nTokens; ++i) {
            TokenWeight memory item = tokens[i];
            assert(isAsset[item.token]);
            targetWeights[item.token] = item.weight;
            total += item.weight;
        }
        totalWeight = total;
        emit TokenWeightSet(tokens);
    }

    function changeOracle(address _oracle) external onlyOwner {
        _requireAddress(_oracle);
        IOracle oldOracle = IOracle(address(oracle));
        oracle = IOracle(_oracle);
        emit OracleChange(address(oldOracle), address(oracle));
    }

    function withdrawFee(address _token, address _recipient) external onlyAsset(_token) onlyOwner {
        uint256 amount = poolAssets[_token].feeReserve;
        poolAssets[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
        emit DaoFeeWithdrawn(_token, _recipient, amount);
    }

    function withdrawWETH(address _token, address _recipient) external onlyAsset(_token) onlyOwner {
        uint256 amount = IERC20(_token).balanceOf(address(this));
        poolAssets[_token].feeReserve = 0;
        _doTransferOut(_token, _recipient, amount);
    }

    function setMaxLeverage(uint256 _maxLeverage) external onlyOwner {
        _setMaxLeverage(_maxLeverage);
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
        (uint256 price, uint256 lastTimestamp) = oracle.getLastPrice(_token);
        if (block.timestamp - lastTimestamp > TIME_OUT_ORACLE) {
            revert TimeOutOracle();
        }
        return price;
    }

    function _getLastPrice(address _token) internal view returns (uint256, uint256) {
        return oracle.getLastPrice(_token);
    }

    function _calcRemoveLiquidity(address _tokenOut, uint256 _lpAmount) internal view returns (uint256 outAmount) {
        uint256 priceToken = _getPrice(_tokenOut);
        uint256 poolValue = _getPoolValue();
        uint256 totalLp = lpToken.totalSupply();
        outAmount = (_lpAmount * poolValue) / totalLp / priceToken;
    }

    function _calcAddLiquidity(address _tokenIn, uint256 _amount, uint256 priceToken)
        internal
        view
        returns (uint256 outLpAmount, uint256 feeAmount)
    {
        uint256 totalPoolValue = _getPoolValue();
        uint256 totalLP = lpToken.totalSupply();
        uint256 valueChange = _amount * priceToken;
        uint256 feeRate =
            _calcFeeRate(_tokenIn, priceToken, valueChange, fee.baseAddRemoveLiquidityFee, fee.taxBasisPoint, true);
        uint256 userAmount = MathUtils.frac(_amount, PRECISION - feeRate, PRECISION);
        feeAmount = _amount - userAmount;
        if (totalLP > 0) {
            outLpAmount = MathUtils.frac(userAmount * priceToken, totalLP, totalPoolValue);
        } else {
            outLpAmount = MathUtils.frac(userAmount, priceToken, LP_INITIAL_PRICE);
        }
    }

    function _requireAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert ZeroAddress();
        }
    }

    function _calcDaoFee(uint256 _feeAmount) internal view returns (uint256 daoFee, uint256 lpFee) {
        daoFee = MathUtils.frac(_feeAmount, fee.daoFee, PRECISION);
        lpFee = _feeAmount - daoFee;
    }

    function _calcSwapOutput(address _tokenIn, address _tokenOut, uint256 _amountIn)
        internal
        view
        returns (uint256 amountOutAfterFee, uint256 feeAmount)
    {
        uint256 priceIn = _getPrice(_tokenIn);
        uint256 priceOut = _getPrice(_tokenOut);
        uint256 valueChange = _amountIn * priceIn;
        uint256 feeIn = _calcSwapFee(_tokenIn, priceIn, valueChange, true);
        uint256 feeOut = _calcSwapFee(_tokenOut, priceOut, valueChange, false);
        uint256 _fee = feeIn > feeOut ? feeIn : feeOut;

        amountOutAfterFee = valueChange * (PRECISION - _fee) / priceOut / PRECISION;
        feeAmount = (valueChange * _fee) / priceIn / PRECISION;
    }

    function _calcSwapFee(address _token, uint256 _tokenPrice, uint256 _valueChange, bool _isSwapIn)
        internal
        view
        returns (uint256)
    {
        (uint256 baseSwapFee, uint256 taxBasisPoint) = isStableCoin[_token]
            ? (fee.stableCoinBaseSwapFee, fee.stableCoinTaxBasisPoint)
            : (fee.baseSwapFee, fee.taxBasisPoint);
        return _calcFeeRate(_token, _tokenPrice, _valueChange, baseSwapFee, taxBasisPoint, _isSwapIn);
    }

    function _calcFeeRate(
        address _token,
        uint256 _tokenPrice,
        uint256 _valueChange,
        uint256 _baseFee,
        uint256 _taxBasisPoint,
        bool _isIncrease
    ) internal view returns (uint256) {
        uint256 _targetValue = totalWeight == 0 ? 0 : (targetWeights[_token] * _getPoolValue()) / totalWeight;
        if (_targetValue == 0) {
            return _baseFee;
        }
        uint256 _currentAmount = IERC20(_token).balanceOf(address(this)) - poolAssets[_token].feeReserve;
        uint256 _currentValue = _tokenPrice * _currentAmount;
        uint256 _nextValue = _isIncrease ? _currentValue + _valueChange : _currentValue - _valueChange;
        uint256 initDiff = MathUtils.diff(_currentValue, _targetValue);
        uint256 nextDiff = MathUtils.diff(_nextValue, _targetValue);
        if (nextDiff < initDiff) {
            uint256 feeAdjust = (_taxBasisPoint * initDiff) / _targetValue;
            return MathUtils.zeroCapSub(_baseFee, feeAdjust);
        } else {
            uint256 avgDiff = (initDiff + nextDiff) / 2;
            uint256 feeAdjust = avgDiff > _targetValue ? _taxBasisPoint : (_taxBasisPoint * avgDiff) / _targetValue;
            return _baseFee + feeAdjust;
        }
    }

    function _getPositionKey(address _owner, address _indexToken, address _collateralToken, Side _side)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(_owner, _indexToken, _collateralToken, _side));
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

    function _setMaxLeverage(uint256 _maxLeverage) internal {
        if (_maxLeverage == 0) {
            revert InvalidMaxLeverage();
        }
        maxLeverage = _maxLeverage;
        emit MaxLeverageChanged(_maxLeverage);
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
    )
        internal
        view
        returns (
            uint256 payoutAmount,
            uint256 collateralReduced,
            int256 remainingCollateral,
            uint256 reserveReduced,
            uint256 indexPrice,
            int256 pnl,
            uint256 feeValue
        )
    {
        collateralReduced = _position.collateralValue < _collateralChanged || _position.size == _sizeChanged
            ? _position.collateralValue
            : _collateralChanged;
        indexPrice = oracle.getPrice(_indexToken);
        uint256 collateralPrice = oracle.getPrice(_collateralToken);
        reserveReduced = (_position.reserveAmount * _sizeChanged) / _position.size;
        pnl = PositionUtils.calcPnl(_side, _sizeChanged, _position.entryPrice, indexPrice);
        feeValue = _calcPositionFee(_position, _sizeChanged, poolAssets[_collateralToken].borrowIndex);
        int256 payoutValue = pnl + collateralReduced.toInt256() - feeValue.toInt256();
        if (isLiquidate) {
            payoutValue = payoutValue - fee.liquidationFee.toInt256();
        }
        remainingCollateral = (_position.collateralValue - collateralReduced).toInt256();
        if (payoutValue < 0) {
            remainingCollateral = remainingCollateral + payoutValue;
            payoutValue = 0;
        }
        payoutAmount = uint256(payoutValue / collateralPrice.toInt256());
        int256 poolValueReduced = pnl;
        if (remainingCollateral < 0) {
            if (!isLiquidate) {
                revert UpdateCauseLiquidation();
            }
            // if liquidate too slow, pool must take the lost
            poolValueReduced = poolValueReduced - int256(remainingCollateral);
            remainingCollateral = 0;
        }
        if (_side == Side.LONG) {
            poolValueReduced = poolValueReduced + int256(collateralReduced);
        } else if (poolValueReduced < 0) {
            // in case of SHORT, trader can lost unlimited value but pool can only increase at most collateralValue - liquidationFee
            poolValueReduced =
                poolValueReduced.cap(MathUtils.zeroCapSub(_position.collateralValue, feeValue + fee.liquidationFee));
        }
    }

    function _liquidatePositionAllowed(Position memory _position, Side _side, uint256 _indexPrice, uint256 _borrowIndex)
        internal
        view
        returns (bool)
    {
        if (_position.size == 0) {
            console.log("hhhhhhhh0");
            return false;
        }
        // calculate fee needed when close position
        uint256 feeValue = _calcPositionFee(_position, _position.size, _borrowIndex);
        int256 pnl = PositionUtils.calcPnl(_side, _position.size, _position.entryPrice, _indexPrice);
        int256 collateral = pnl + _position.collateralValue.toInt256();
        console.log("collateral");
        console.logInt(collateral);
        console.log("feeValue",feeValue);
        console.log("fee.liquidationFee",fee.liquidationFee);
        // liquidation occur when collateral cannot cover margin fee
        return collateral < 0 || uint256(collateral) < (feeValue + fee.liquidationFee);
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount != 0) {
            IERC20 token = IERC20(_token);
            token.transfer(_to, _amount);
        }
    }

    function _calcPositionFee(Position memory _position, uint256 _sizeChanged, uint256 _borrowIndex)
        internal
        view
        returns (uint256 feeValue)
    {
        uint256 borrowFee = ((_borrowIndex - _position.borrowIndex) * _position.size) / PRECISION;
        uint256 positionFee = (_sizeChanged * fee.positionFee) / PRECISION;
        feeValue = borrowFee + positionFee;
    }

    function _accrueInterest(address _token) internal returns (uint256) {
        AssetInfo memory tokenInfo = poolAssets[_token];
        uint256 _now = block.timestamp;
        if (tokenInfo.lastAccrualTimestamp == 0 || tokenInfo.poolAmount == 0) {
            tokenInfo.lastAccrualTimestamp = (_now / accrualInterval) * accrualInterval;
        } else {
            uint256 nInterval = (_now - tokenInfo.lastAccrualTimestamp) / accrualInterval;
            if (nInterval == 0) {
                return tokenInfo.borrowIndex;
            }

            tokenInfo.borrowIndex += (nInterval * interestRate * tokenInfo.reservedAmount) / tokenInfo.poolAmount;
            tokenInfo.lastAccrualTimestamp += nInterval * accrualInterval;
        }

        poolAssets[_token] = tokenInfo;
        emit InterestAccrued(_token, tokenInfo.borrowIndex);
        return tokenInfo.borrowIndex;
    }

    // ========= Event ===============

    event AddPoolToken(address token);
    event SetOrderManager(address manager);
    event OracleChange(address oldOracle, address newOracle);
    event MaxLeverageChanged(uint256 levarage);
    event RemoveLiquidity(address wallet, address tokenOut, uint256 amount, uint256 markPrice);
    event TokenWeightSet(TokenWeight[]);
    event DaoFeeWithdrawn(address indexed token, address recipient, uint256 amount);
    event AddLiquidity(address wallet, address asset, uint256 amount, uint256 fee, uint256 markPriceIn);
    event IncreasePosition(
        address indexed account,
        address indexToken,
        address collateralToken,
        address collateral,
        uint256 sizeChanged,
        bool side
    );
    event DecreasePosition(
        address indexed account,
        address indexToken,
        address collateralToken,
        address collateral,
        uint256 sizeChanged,
        bool side
    );
    event Swap(
        address indexed sender,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 fee,
        uint256 markPrice
    );
    event InterestAccrued(address indexed token, uint256 borrowIndex);
    event IncreasePosition(
        bytes32 indexed key,
        address wallet,
        address collateralToken,
        address indexToken,
        uint256 collateralValue,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        uint256 feeValue
    );
    event DecreasePosition(
        bytes32 indexed key,
        address wallet,
        address collateralToken,
        address indexToken,
        uint256 collateralChanged,
        uint256 sizeChanged,
        Side side,
        uint256 indexPrice,
        SignedInt pnl,
        uint256 feeValue,
        DecreaseType decreaseType
    );

    // ========= Error ===============
    error NotAsset(address token);
    error NotListed(address token);
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
    error DuplicateToken(address token);
    error TimeOutOracle();
    error RequireAllTokens();
    error TooManyTokenAdded(uint256 number, uint256 max);
}
