// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DusdERC20} from "./DusdERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";

/**
 * @title DusdEngine
 * @author Juan Duzac
 * The system is designed to be as minimal as possible
 * and have the tokens maintain a 1 to 1 peg to USD.
 * This stable coin has the properties:
 * - Exogenous collateral
 * - Dollar pegged
 * - Algorithmically stable
 *
 * Always backed by wBTC and wETH.
 * Should always be "overcollateralized". At no point, should the value
 * of all collateral be <= the $USD backed value of all DUSD system.
 *
 * @notice This contract is the core of the DUSD system. It handles all the
 * logic for minting and redeeming DUSD, as well as depositing & withdrawing collateral.
 */
contract DusdEngine is ReentrancyGuard {
    /* Errors */
    error DusdEngine__MoreThanZeroNeeded();
    error DusdEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DusdEngine__TokenNotAllowed(address token);
    error DusdEngine__TransferFailed();
    error DusdEngine__BreaksHealthFactor(uint256 healthFactor);
    error DusdEngine__MintFailed();
    error DusdEngine__HealthFactorOk();
    error DusdEngine__HealthFactorNotImproved();

    /* Types */
    using OracleLib for AggregatorV3Interface;

    /* State variables */
    DusdERC20 private immutable i_DUSD;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    mapping(address collateralToken => address priceFeed) private s_priceFeeds;

    address[] private s_collateralTokens;

    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposit;
    mapping(address user => uint256 DUSDMinted) private s_DUSDMinted;

    /* Events */
    event CollateralDeposited(address indexed user, address indexed tokenAddress, uint256 indexed collateralAmount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address tokenAddress, uint256 amount
    );

    /* Modifiers */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) {
            revert DusdEngine__MoreThanZeroNeeded();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DusdEngine__TokenNotAllowed(token);
        }
        _;
    }

    /* Functions */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dusdAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DusdEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_DUSD = DusdERC20(dusdAddress);
    }

    /* External Functions */

    /**
     *
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param collateralAmount The amount of collateral to deposit
     * @param mintAmount The amount of DUSD to mint
     * @notice This function will deposit the collateral and mint the DUSD in one transaction
     */
    function depositCollateralAndMintDusd(address tokenCollateralAddress, uint256 collateralAmount, uint256 mintAmount)
        external
    {
        depositCollateral(tokenCollateralAddress, collateralAmount);
        mintDusd(mintAmount);
    }

    /**
     *
     * @param tokenCollateralAddress: The address of the token to deposit as collateral
     * @param collateralAmount : The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposit[msg.sender][tokenCollateralAddress] = collateralAmount;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, collateralAmount);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) {
            revert DusdEngine__TransferFailed();
        }
    }

    /**
     *
     * @param tokenCollateralAddress The collateral address to redeem
     * @param collateralAmount The amount of collateral to redeem
     * @param amountToBurn The amount of DUSD to burn
     * This function burns DUSD and redeems collataral in one transaction
     */
    function redeemCollateralForDusd(address tokenCollateralAddress, uint256 collateralAmount, uint256 amountToBurn)
        external
    {
        burnDusd(amountToBurn);
        redeemCollateral(tokenCollateralAddress, collateralAmount);
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 collateralAmount)
        public
        moreThanZero(collateralAmount)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, collateralAmount);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @param dusdToMint The amount of DUSD to mint
     * @notice User must have more collateral value than the minimum threshold
     */
    function mintDusd(uint256 dusdToMint) public moreThanZero(dusdToMint) nonReentrant {
        s_DUSDMinted[msg.sender] += dusdToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool success = i_DUSD.mint(msg.sender, dusdToMint);
        if (!success) {
            revert DusdEngine__MintFailed();
        }
    }

    function burnDusd(uint256 amount) public moreThanZero(amount) {
        _burnDusd(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * @param tokenCollateralAddress The ERC20 Collateral address to liquidate from the user
     * @param user The user address whom has broken the health factor.
     * Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DUSD wanted to burn to imporve users health factor
     * @notice You can partially liqudiate a user.
     * @notice You will get a liquidation bonus for taking the user funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work.
     */
    function liquidate(address tokenCollateralAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DusdEngine__HealthFactorOk();
        }
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateralAddress, debtToCover);
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, tokenCollateralAddress, totalCollateralToRedeem);
        _burnDusd(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DusdEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /////////////////////////////////////////
    /* Private and internal view functions */
    /////////////////////////////////////////

    function _calculateHealthFactor(uint256 totalDusdMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDusdMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDusdMinted;
    }

    /**
     * @dev Low level internal function.
     * Do not call this unless the function calling is checking for healthFactor being broken
     */
    function _burnDusd(uint256 amount, address onBehalfOf, address dusdFrom) public moreThanZero(amount) {
        s_DUSDMinted[onBehalfOf] -= amount;
        bool success = i_DUSD.transferFrom(dusdFrom, address(this), amount);
        if (!success) {
            revert DusdEngine__TransferFailed();
        }
        i_DUSD.burn(amount);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 collateralAmount)
        private
    {
        // No unsafe math, checks needed?
        s_collateralDeposit[from][tokenCollateralAddress] -= collateralAmount;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, collateralAmount);
        bool succcess = IERC20(tokenCollateralAddress).transfer(to, collateralAmount);
        if (!succcess) {
            revert DusdEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDUSDMinted, uint256 collateralValueInUSD)
    {
        totalDUSDMinted = s_DUSDMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * Returns how close to liquidation a user is
     * if a user goes below 1, they can get liquidated
     * @param user The user address
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDusdMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDusdMinted, collateralValueInUsd);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DusdEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////////////
    /* Public and external view functions */
    /////////////////////////////////////////
    function calculateHealthFactor(uint256 totalDusdMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDusdMinted, collateralValueInUsd);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDusdMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposit[user][token];
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposit[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDusd() external view returns (address) {
        return address(i_DUSD);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}
