// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Validation {
    /**
     * @dev Validates that the given ERC20 token contract has a valid `decimals()` function.
     * @param token The address of the ERC20 token contract to validate.
     * @return `true` if the token contract has a valid `decimals()` function, `false` otherwise.
     */
    function validateERC20Token(address token) internal view returns (bool) {
        bytes4 decimalSig = bytes4(keccak256("decimals()"));
        (bool success, bytes memory returnData) = token.staticcall(abi.encodeWithSelector(decimalSig));
        return success && returnData.length == 32;
    }
}