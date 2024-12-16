// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Address {
    /**
     * @dev Checks if the given address is a valid contract address.
     * @param _address The address to check.
     * @return true if the address is a contract, false otherwise.
     */
    function isCorrect(address _address) internal view returns (bool) {
        return _address.code.length > 0 && _address != address(0);
    }

    /**
     * @dev Checks if the given address is the zero address.
     * @param _address The address to check.
     * @return true if the address is the zero address, false otherwise.
     */
    function isZeroAddress(address _address) internal pure returns (bool) {
        return _address == address(0);
    }
}
