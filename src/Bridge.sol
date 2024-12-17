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

    uint256 public constant COOLDOWN = 1 minutes;
    mapping(address => uint256) private _lastAccessTime;

    uint256 private _totalDistribution;
    uint256 private _totalReceivedTokens;

    modifier isValidContract(address _address) {
        if(!_address.isCorrect()){
            revert();
        }
        _;
    }

    modifier validAddress(address _address) {
        if(_address.isZeroAddress()) {
            revert();
        }
        _;
    }

    modifier cooldownTimer(address user) {
        uint256 lastAccess = _lastAccessTime[user];
        uint256 elapsed = block.timestamp - lastAccess;
        if(elapsed < COOLDOWN) {
            revert();
        }
        _;
        _lastAccessTime[user] = block.timestamp;
    }

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

    function send(
        SendParam calldata _sendParam,
        bytes calldata _extraOptions,
        MessagingFee calldata _fee,
        address _refundAddress,
        bytes calldata _composeMsg,
        bytes calldata /*_oftCmd*/ // @dev unused in the default implementation.
    ) external payable override nonReentrant whenNotPaused cooldownTimer(msg.sender) returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {

        (uint256 amountDebitedLD, uint256 amountToCreditLD) = _debit(
            _sendParam.amountToSendLD,
            _sendParam.minAmountToCreditLD,
            _sendParam.dstEid
        );

        // @dev Builds the options and OFT message to quote in the endpoint.
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(
            _sendParam,
            _extraOptions,
            _composeMsg,
            amountToCreditLD
        );
        (msgReceipt, oftReceipt) = _generateReceipt(_sendParam.dstEid, message, options, _fee, _refundAddress, amountDebitedLD, amountToCreditLD);
    }

    function _generateReceipt(uint32 dstId, bytes memory message, bytes memory options, MessagingFee calldata fee, address _refundAddress, uint256 amountDebited, uint256 amountCredited) internal returns (MessagingReceipt memory, OFTReceipt memory) {
        MessagingReceipt memory msgReceipt = _lzSend(dstId, message, options, fee, _refundAddress);
        // @dev Formulate the OFT receipt.
        OFTReceipt memory oftReceipt = OFTReceipt(amountDebited, amountCredited);
        return (msgReceipt, oftReceipt);

    }

    function _debit(uint256 _amount, uint256 _minAmount, uint32 _dstId) internal virtual override returns (uint256 amountSent, uint256 amountReceived) {
        (amountSent, amountReceived) = _debitView(_amount, _minAmount, _dstId);
        _innerToken.safeTransferFrom(msg.sender, address(this), amountSent);
    }
    function _credit(address to, uint256 amount, uint32 /*srcId*/) internal virtual override returns (uint256 amountReceived) {
        _innerToken.safeTransfer(to, amount);
        return amount;
    }

    function _debitSender(
        uint256 _amountToSendLD,
        uint256 _minAmountToCreditLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountDebitedLD, uint256 amountToCreditLD){}

    function _debitThis(
        uint256 _minAmountToCreditLD,
        uint32 _dstEid
    ) internal override returns (uint256 amountDebitedLD, uint256 amountToCreditLD){}

    function oftVersion() external pure override returns (uint64 major, uint64 minor) {
        return (1, 0);
    }

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

    function rescueToken(address _token, address _to, uint256 _amount) external isValidContract(_token) validAddress(_to) onlyOwner {}
    function withdraw() external onlyOwner {}

}
