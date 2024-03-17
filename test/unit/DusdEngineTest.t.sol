// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {DeployDUSD} from "../../script/DeployDUSD.s.sol";
import {DusdEngine} from "../../src/DusdEngine.sol";
import {DusdERC20} from "../../src/DusdERC20.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockMoreDebtDUSD} from "../mocks/MockMoreDebtDUSD.sol";
import {MockFailedMintDUSD} from "../mocks/MockFailedMintDUSD.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract DusdEngineTest is StdCheats, Test {
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    DusdEngine public dusde;
    DusdERC20 public dusd;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;
    address public user = address(1);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        DeployDUSD deployer = new DeployDUSD();
        (dusd, dusde, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        // Should we put our integration tests here?
        // else {
        //     user = vm.addr(deployerKey);
        //     ERC20Mock mockErc = new ERC20Mock("MOCK", "MOCK", user, 100e18);
        //     MockV3Aggregator aggregatorMock = new MockV3Aggregator(
        //         helperConfig.DECIMALS(),
        //         helperConfig.ETH_USD_PRICE()
        //     );
        //     vm.etch(weth, address(mockErc).code);
        //     vm.etch(wbtc, address(mockErc).code);
        //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
        //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
        // }
        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public feedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        feedAddresses.push(ethUsdPriceFeed);
        feedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DusdEngine.DusdEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DusdEngine(tokenAddresses, feedAddresses, address(dusd));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetTokenAmountFromUsd() public view {
        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
        uint256 expectedWeth = 0.05 ether;
        uint256 amountWeth = dusde.getTokenAmountFromUsd(weth, 100 ether);
        assertEq(amountWeth, expectedWeth);
    }

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 usdValue = dusde.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    ///////////////////////////////////////
    // depositCollateral Tests //
    ///////////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDusd = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDusd)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DusdEngine mockDusde = new DusdEngine(tokenAddresses, feedAddresses, address(mockDusd));
        mockDusd.mint(user, amountCollateral);

        vm.prank(owner);
        mockDusd.transferOwnership(address(mockDusde));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDusd)).approve(address(mockDusde), amountCollateral);
        // Act / Assert
        vm.expectRevert(DusdEngine.DusdEngine__TransferFailed.selector);
        mockDusde.depositCollateral(address(mockDusd), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);

        vm.expectRevert(DusdEngine.DusdEngine__MoreThanZeroNeeded.selector);
        dusde.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(DusdEngine.DusdEngine__TokenNotAllowed.selector, address(randToken)));
        dusde.depositCollateral(address(randToken), amountCollateral);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = dusd.balanceOf(user);
        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDusdMinted, uint256 collateralValueInUsd) = dusde.getAccountInformation(user);
        uint256 expectedDepositedAmount = dusde.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDusdMinted, 0);
        assertEq(expectedDepositedAmount, amountCollateral);
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDusd Tests //
    ///////////////////////////////////////

    function testRevertsIfMintedDusdBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dusde.getAdditionalFeedPrecision())) / dusde.getPrecision();
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);

        uint256 expectedHealthFactor =
            dusde.calculateHealthFactor(amountToMint, dusde.getUsdValue(weth, amountCollateral));
        vm.expectRevert(
            abi.encodeWithSelector(DusdEngine.DusdEngine__BreaksHealthFactor.selector, expectedHealthFactor)
        );
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDusd() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    function testCanMintWithDepositedCollateral() public depositedCollateralAndMintedDusd {
        uint256 userBalance = dusd.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // mintDusd Tests //
    ///////////////////////////////////
    // This test needs it's own custom setup
    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintDUSD mockDusd = new MockFailedMintDUSD();
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DusdEngine mockDusde = new DusdEngine(tokenAddresses, feedAddresses, address(mockDusd));
        mockDusd.transferOwnership(address(mockDusde));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDusde), amountCollateral);

        vm.expectRevert(DusdEngine.DusdEngine__MintFailed.selector);
        mockDusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.expectRevert(DusdEngine.DusdEngine__MoreThanZeroNeeded.selector);
        dusde.mintDusd(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        // 0xe580cc6100000000000000000000000000000000000000000000000006f05b59d3b20000
        // 0xe580cc6100000000000000000000000000000000000000000000003635c9adc5dea00000
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dusde.getAdditionalFeedPrecision())) / dusde.getPrecision();

        vm.startPrank(user);
        uint256 expectedHealthFactor =
            dusde.calculateHealthFactor(amountToMint, dusde.getUsdValue(weth, amountCollateral));
        vm.expectRevert(
            abi.encodeWithSelector(DusdEngine.DusdEngine__BreaksHealthFactor.selector, expectedHealthFactor)
        );
        dusde.mintDusd(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDusd() public depositedCollateral {
        vm.prank(user);
        dusde.mintDusd(amountToMint);

        uint256 userBalance = dusd.balanceOf(user);
        assertEq(userBalance, amountToMint);
    }

    ///////////////////////////////////
    // burnDusd Tests //
    ///////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.expectRevert(DusdEngine.DusdEngine__MoreThanZeroNeeded.selector);
        dusde.burnDusd(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(user);
        vm.expectRevert();
        dusde.burnDusd(1);
    }

    function testCanBurnDusd() public depositedCollateralAndMintedDusd {
        vm.startPrank(user);
        dusd.approve(address(dusde), amountToMint);
        dusde.burnDusd(amountToMint);
        vm.stopPrank();

        uint256 userBalance = dusd.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDusd = new MockFailedTransfer();
        tokenAddresses = [address(mockDusd)];
        feedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DusdEngine mockDusde = new DusdEngine(tokenAddresses, feedAddresses, address(mockDusd));
        mockDusd.mint(user, amountCollateral);

        vm.prank(owner);
        mockDusd.transferOwnership(address(mockDusde));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(address(mockDusd)).approve(address(mockDusde), amountCollateral);
        // Act / Assert
        mockDusde.depositCollateral(address(mockDusd), amountCollateral);
        vm.expectRevert(DusdEngine.DusdEngine__TransferFailed.selector);
        mockDusde.redeemCollateral(address(mockDusd), amountCollateral);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.expectRevert(DusdEngine.DusdEngine__MoreThanZeroNeeded.selector);
        dusde.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(user);
        dusde.redeemCollateral(weth, amountCollateral);
        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
        assertEq(userBalance, amountCollateral);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dusde));
        emit CollateralRedeemed(user, user, weth, amountCollateral);
        vm.startPrank(user);
        dusde.redeemCollateral(weth, amountCollateral);
        vm.stopPrank();
    }
    ///////////////////////////////////
    // redeemCollateralForDusd Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositedCollateralAndMintedDusd {
        vm.startPrank(user);
        dusd.approve(address(dusde), amountToMint);
        vm.expectRevert(DusdEngine.DusdEngine__MoreThanZeroNeeded.selector);
        dusde.redeemCollateralForDusd(weth, 0, amountToMint);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        dusd.approve(address(dusde), amountToMint);
        dusde.redeemCollateralForDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        uint256 userBalance = dusd.balanceOf(user);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositedCollateralAndMintedDusd {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dusde.getHealthFactor(user);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 collatareral at all times.
        // 20,000 * 0.5 = 10,000
        // 10,000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedDusd {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dusde.getHealthFactor(user);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDusdMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        MockMoreDebtDUSD mockDusd = new MockMoreDebtDUSD(ethUsdPriceFeed);
        tokenAddresses = [weth];
        feedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DusdEngine mockDusde = new DusdEngine(tokenAddresses, feedAddresses, address(mockDusd));
        mockDusd.transferOwnership(address(mockDusde));
        // Arrange - User
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(mockDusde), amountCollateral);
        mockDusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockDusde), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockDusde.depositCollateralAndMintDusd(weth, collateralToCover, amountToMint);
        mockDusd.approve(address(mockDusde), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(DusdEngine.DusdEngine__HealthFactorNotImproved.selector);
        mockDusde.liquidate(weth, user, debtToCover);
        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDusd {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dusde), collateralToCover);
        dusde.depositCollateralAndMintDusd(weth, collateralToCover, amountToMint);
        dusd.approve(address(dusde), amountToMint);

        vm.expectRevert(DusdEngine.DusdEngine__HealthFactorOk.selector);
        dusde.liquidate(weth, user, amountToMint);
        vm.stopPrank();
    }

    modifier liquidated() {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateralAndMintDusd(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dusde.getHealthFactor(user);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dusde), collateralToCover);
        dusde.depositCollateralAndMintDusd(weth, collateralToCover, amountToMint);
        dusd.approve(address(dusde), amountToMint);
        dusde.liquidate(weth, user, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = dusde.getTokenAmountFromUsd(weth, amountToMint)
            + (dusde.getTokenAmountFromUsd(weth, amountToMint) / dusde.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dusde.getTokenAmountFromUsd(weth, amountToMint)
            + (dusde.getTokenAmountFromUsd(weth, amountToMint) / dusde.getLiquidationBonus());

        uint256 usdAmountLiquidated = dusde.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dusde.getUsdValue(weth, amountCollateral) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dusde.getAccountInformation(user);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorDusdMinted,) = dusde.getAccountInformation(liquidator);
        assertEq(liquidatorDusdMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDusdMinted,) = dusde.getAccountInformation(user);
        assertEq(userDusdMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////
    function testGetCollateralTokenPriceFeed() public view {
        address priceFeed = dusde.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public view {
        address[] memory collateralTokens = dusde.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public view {
        uint256 minHealthFactor = dusde.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public view {
        uint256 liquidationThreshold = dusde.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositedCollateral {
        (, uint256 collateralValue) = dusde.getAccountInformation(user);
        uint256 expectedCollateralValue = dusde.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralBalance = dusde.getCollateralBalanceOfUser(user, weth);
        assertEq(collateralBalance, amountCollateral);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dusde), amountCollateral);
        dusde.depositCollateral(weth, amountCollateral);
        vm.stopPrank();
        uint256 collateralValue = dusde.getAccountCollateralValue(user);
        uint256 expectedCollateralValue = dusde.getUsdValue(weth, amountCollateral);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDusd() public view {
        address dusdAddress = dusde.getDusd();
        assertEq(dusdAddress, address(dusd));
    }

    function testLiquidationPrecision() public view {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dusde.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDusd {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = dusd.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dusde));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dusde));

    //     uint256 wethValue = dusde.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = dusde.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
