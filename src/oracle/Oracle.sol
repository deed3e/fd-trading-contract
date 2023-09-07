// SPDX-License-Identifier: MIT

pragma solidity >=0.8.19;

import {Ownable} from "openzeppelin/access/Ownable.sol";
import {IOracle} from "../interfaces/IOracle.sol";

struct TokenConfig {
    uint256 baseUnits;
    uint256 priceUnits;
}

/// @title PriceFeed
/// @notice Price feed with guard from
contract Oracle is Ownable, IOracle {
    uint256 public constant VALUE_PRECISION = 1e30;
    mapping(address => TokenConfig) public tokenConfig;
    mapping(address => uint256) public lastAnswers;
    mapping(address => uint256) public lastAnswerTimestamp;
    mapping(address => uint256) public lastAnswerBlock;

    mapping(address => bool) public isReporter;
    address[] public reporters;

    // ============ Mutative functions ============

    function postPrices(address[] calldata tokens, uint256[] calldata prices) external {
        require(isReporter[msg.sender], "PriceFeed:unauthorized");
        uint256 count = tokens.length;
        require(prices.length == count, "PriceFeed:lengthMissMatch");
        for (uint256 i = 0; i < count;) {
            _postPrice(tokens[i], prices[i]);
            unchecked {
                ++i;
            }
        }
    }

    // ============ View functions ============
    function getMultiplePrices(address[] calldata tokens) external view returns (uint256[] memory) {
        uint256 len = tokens.length;
        uint256[] memory result = new uint256[](len);

        for (uint256 i = 0; i < len;) {
            result[i] = _getPrice(tokens[i]);
            unchecked {
                ++i;
            }
        }

        return result;
    }

    function getPrice(address token) external view returns (uint256) {
        return _getPrice(token);
    }

    function getLastPrice(address token) external view returns (uint256 lastPrice, uint256 timestamp) {
        (lastPrice, timestamp) = _getLastPrice(token);
    }

    // =========== Restrited functions ===========
    /// @notice config watched token
    /// @param token token address
    /// @param tokenDecimals token decimals
    /// @param priceDecimals precision of price posted by reporter, not the chainlink price feed
    function configToken(address token, uint256 tokenDecimals, uint256 priceDecimals) external onlyOwner {
        require(token != address(0), "PriceFeed:invalidToken");
        require(tokenDecimals != 0 && priceDecimals != 0, "PriceFeed:invalidDecimals");

        tokenConfig[token] = TokenConfig({baseUnits: 10 ** tokenDecimals, priceUnits: 10 ** priceDecimals});
        emit TokenAdded(token);
    }

    function addReporter(address reporter) external onlyOwner {
        require(!isReporter[reporter], "PriceFeed:reporterAlreadyAdded");
        isReporter[reporter] = true;
        reporters.push(reporter);
        emit ReporterAdded(reporter);
    }

    function removeReporter(address reporter) external onlyOwner {
        require(reporter != address(0), "PriceFeed:invalidAddress");
        require(isReporter[reporter], "PriceFeed:reporterNotExists");
        isReporter[reporter] = false;
        for (uint256 i = 0; i < reporters.length; i++) {
            if (reporters[i] == reporter) {
                reporters[i] = reporters[reporters.length - 1];
                break;
            }
        }
        reporters.pop();
        emit ReporterRemoved(reporter);
    }

    function _postPrice(address token, uint256 price) internal {
        TokenConfig memory config = tokenConfig[token];
        require(config.baseUnits > 0, "PriceFeed:tokenNotConfigured");
        lastAnswers[token] = (price * VALUE_PRECISION) / config.baseUnits / config.priceUnits;
        lastAnswerTimestamp[token] = block.timestamp;
        lastAnswerBlock[token] = block.number;
        emit PricePosted(token, price);
    }

    function _getPrice(address token) internal view returns (uint256) {
        (uint256 lastPrice,) = _getLastPrice(token);
        return lastPrice;
    }

    function _getLastPrice(address token) internal view returns (uint256 price, uint256 timestamp) {
        return (lastAnswers[token], lastAnswerTimestamp[token]);
    }

    // =========== Events ===========
    event TokenAdded(address token);
    event ReporterAdded(address indexed);
    event ReporterRemoved(address indexed);
    event PricePosted(address indexed token, uint256 price);
}
