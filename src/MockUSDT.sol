// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockUSDT is ERC20, ERC20Burnable, Ownable {
    using SafeERC20 for ERC20;

    constructor() ERC20("MockUSDT", "USDT") {
        _mint(msg.sender, 50000000000 * 10 ** decimals());
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return 6;
    }
}
