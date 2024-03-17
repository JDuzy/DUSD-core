// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockFailedTransferFrom is ERC20Burnable, Ownable {
    error DusdERC20__MustBeMoreThanZero();
    error DusdERC20__BurnAmountExceedsBalance();
    error DusdERC20__NotZeroAddress();

    constructor() ERC20("Duz USD", "DUSD") {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DusdERC20__MustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DusdERC20__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address account, uint256 amount) public {
        _mint(account, amount);
    }

    function transferFrom(address, /*sender*/ address, /*recipient*/ uint256 /*amount*/ )
        public
        pure
        override
        returns (bool)
    {
        return false;
    }
}
