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
address constant ETH = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

struct AssetInfo {
    uint256 feeReserve;
    bool isStableCoin;
}

struct Fee {
    uint256 baseSwapFee;
    uint256 positionFee;
    uint256 liquidationFee;
    uint256 borrowFee;
}

contract Pool is Ownable {
    using SignedIntOps for int256;
    using SafeCast for uint256;

    /* =========== Statement  ======== */
    Fee public fee;
    IOracle public oracle;
    mapping(address => AssetInfo) public poolAssets;
    address[] public allAssets;
    mapping(address => bool) public isAsset;
    mapping(address => bool) public isListed;
    ILPToken public lpToken;

    /* =========== MODIFIERS ========== */
    constructor(address _oracle) {
        oracle = IOracle(_oracle);
    }

    modifier onlyAsset(address _token) {
        if (!isAsset[_token]) {
            revert NotAsset(_token);
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

    // ========= Admin functions ========
    function withdrawETH() external onlyOwner {
        
    }

    function setFee(Fee memory _fee) external onlyOwner {
        fee = _fee;
    }

    function setLpToken(address _lp) external onlyOwner {
        lpToken = ILPToken(_lp);
    }

    function addToken(address _token, bool _isStableCoin, uint256 _feeReserve) external onlyOwner {
         if (isListed[_token]) {
            revert DuplicateToken(_token);
        }
        _requireAddress(_token);
        AssetInfo memory assetInfo;
        assetInfo.isStableCoin = _isStableCoin;
        assetInfo.feeReserve = _feeReserve;
        poolAssets[_token] = assetInfo;
        allAssets.push(_token);
        isAsset[_token] = true;
        isListed[_token] = true;
        emit AddPoolToken(_token);
    }

    function changeOracle(address _oracle) external onlyOwner {
        _requireAddress(_oracle);
        IOracle oldOracle = IOracle(address(oracle));
        oracle = IOracle(_oracle);
        emit OracleChange(address(oldOracle), address(oracle));
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

    function _requireAddress(address _address) internal pure {
        if (_address == address(0)) {
            revert ZeroAddress();
        }
    }

    function _doTransferOut(address _token, address _to, uint256 _amount) internal {
        if (_amount != 0) {
            IERC20 token = IERC20(_token);
            token.transfer(_to, _amount);
        }
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
    error NotAsset(address token);
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
}
