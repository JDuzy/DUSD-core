// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Dusd descentralized stable coin
 * @author Juan Duzac
 * @notice Collateral: Exogenous (BTC, ETH)
 * Minting: Algorithmic
 * Relative stability: Peeged to USD
 *
 * This is the ERC20 implementation contract of the stablecoin
 * meant to be governed by DusdEngine
 */
contract DusdERC20 is ERC20Burnable, Ownable {
    error DusdERC20__MustBeMoreThanZero();
    error DusdERC20__BurnAmountExceedsBalance();
    error DusdERC20__ZeroAddressNotAccepted();

    constructor() ERC20("Duz usd", "DUSD") Ownable() {}

    function burn(uint256 _amount) public override onlyOwner {
        if (_amount <= 0) {
            revert DusdERC20__MustBeMoreThanZero();
        }
        uint256 balance = balanceOf(msg.sender);
        if (_amount > balance) {
            revert DusdERC20__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DusdERC20__ZeroAddressNotAccepted();
        }
        if (_amount <= 0) {
            revert DusdERC20__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
