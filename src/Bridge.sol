// SPDX-Identifier: MIT
pragma solidity ^0.8.26;

import {Address} from "./libs/Address.sol";
import {Validation} from "./libs/Validation.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

import {ILayerZeroEndpointV2} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {
    IOFT,
    SendParam,
    OFTLimit,
    OFTReceipt,
    OFTFeeDetail,
    MessagingReceipt,
    MessagingFee
} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {OFTCore, IERC20, IERC20Metadata, SafeERC20} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/OFTAdapter.sol";

contract Bridge is ReentrancyGuard, Pausable, OFTCore {
    using SafeERC20 for IERC20;
    using Address for address;

    IERC20 internal immutable _innerToken;

    constructor(address _token, address _lzEndpoint, address _delegate)
        OFTCore(IERC20Metadata(_token).decimals(), _lzEndpoint, _delegate)
    {
        if(Validation.validateERC20Token(_token)) {
            revert();
        }
        if(_lzEndpoint.isZeroAddress()) {
            revert();
        }

        _innerToken = IERC20(_token);
    }

    function send(SendParam calldata _sendParam, MessagingFee calldata _fee, address _refundAddress) external payable override nonReentrant whenNotPaused returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {}

    function _debit(uint256 _amount, uint256 _minAmount, uint32 _dstId) internal virtual override returns (uint256 amountSent, uint256 amountReceived) {}
    function _credit(address to, uint256 amount, uint32 srcId) internal virtual override returns (uint256 amountReceived) {}

    function token() external view returns (address) {
        return address(_innerToken);
    }

    function totalSupply() external view returns (uint256) {
        return _innerToken.balanceOf(address(this));
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

}
