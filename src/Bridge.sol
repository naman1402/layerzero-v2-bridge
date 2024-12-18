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

/**
 * @title Bridge
 * @dev A contract that implements a bridge functionality using the LayerZero protocol.
 * The contract allows users to send tokens across different chains, with support for
 * cooldown timers, pausability, and token rescue functionality.
 */
contract Bridge is ReentrancyGuard, Pausable, OFTCore {

    using SafeERC20 for IERC20;
    using Address for address;

    /// @dev address of token that will be   
    IERC20 internal immutable _innerToken;
    /// @dev cooldown timer
    uint256 public constant COOLDOWN = 1 minutes;
    /// @dev mapping that stores last access time for each user
    mapping(address => uint256) private _lastAccessTime;
    /// @dev track token movement metrics
    uint256 private _totalDistribution;
    uint256 private _totalReceivedTokens;

    /// @dev events

    /// @dev custom errors
    error Bridge__InvalidContractInteractrion();
    error Bridge__InvalidAddressInteraction();
    error Bridge__CooldownNotPassed(uint256 remainingTime);
    error Bridge__InvalidToken(address token);

    /**
     * @dev Checks if the provided address is a contract.
     * Reverts with `InvalidContractInteraction` if it's not.
     * @param _address The address to check.
     */
    modifier isValidContract(address _address) {
        if (!_address.isCorrect()) {
            revert Bridge__InvalidContractInteractrion();
        }
        _;
    }

    /**
     * @dev Checks if the provided address is valid (non-zero).
     * Reverts with `InvalidAddressInteraction` if it's not.
     * @param _address The address to check.
     */
    modifier validAddress(address _address) {
        if (_address.isZeroAddress()) {
            revert Bridge__InvalidAddressInteraction();
        }
        _;
    }

    /**
     * @dev Modifier to enforce a cooldown period between user operations.
     * Reverts with `CooldownNotElapsed` if the cooldown period hasn't elapsed since the last operation.
     * @param user The address of the user being checked for cooldown.
     */
    modifier cooldownTimer(address user) {
        uint256 lastAccess = _lastAccessTime[user];
        uint256 elapsed = block.timestamp - lastAccess;
        if (elapsed < COOLDOWN) {
            revert Bridge__CooldownNotPassed(block.timestamp - lastAccess);
        }
        _;
        _lastAccessTime[user] = block.timestamp;
    }

    /**
     * @dev Initializes the Bridge contract with the provided token, LayerZero endpoint, and delegate addresses.
     * Validates the provided token and LayerZero endpoint addresses, and stores the token contract instance.
     * @param _token The address of the ERC20 token used for the bridge.
     * @param _lzEndpoint The address of the LayerZero endpoint contract.
     * @param _delegate The address of the delegate contract.
     */
    constructor(address _token, address _lzEndpoint, address _delegate)
        OFTCore(IERC20Metadata(_token).decimals(), _lzEndpoint, _delegate)
    {
        if (Validation.validateERC20Token(_token)) {
            revert Bridge__InvalidToken(_token);
        }
        if (!_lzEndpoint.isCorrect()) {
            revert Bridge__InvalidContractInteractrion();
        }

        _innerToken = IERC20(_token);
    }

    /**
     * @dev Sends tokens to another chain using LayerZero protocol.
     * Successful send call will be delivered to the destination chain, invoking the provided _lzReceive method during execution
     * When receiving the message on your destination chain, _credit will be invoked, triggering the final steps to transfer tokens on the destination chain to the specified adderss.
     * @param _sendParam The parameters for sending the tokens.
     * @param _fee The messaging fee details.
     * @param _refundAddress The address for refunding any excess fees.
     * @return msgReceipt The receipt of the messaging operation.
     * @return oftReceipt The receipt of the OFT operation.
     */
    function send(
        SendParam calldata _sendParam,
        bytes calldata _extraOptions,
        MessagingFee calldata _fee,
        address _refundAddress,
        bytes calldata _composeMsg,
        bytes calldata /*_oftCmd*/ // @dev unused in the default implementation.
    )
        external
        payable
        override
        nonReentrant
        whenNotPaused
        cooldownTimer(msg.sender)
        returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt)
    {   
        // - amountSentLD is the amount in local decimals that was ACTUALLY sent/debited from the sender.
        // - amountReceivedLD is the amount in local decimals that will be received/credited to the recipient on the remote OFT instance.
        (uint256 amountSentLD, uint256 amountReceivedLD) =
            _debit(_sendParam.amountToSendLD, _sendParam.minAmountToCreditLD, _sendParam.dstEid);

        /// @dev builds the options and OFT message to qoute in the endpoint
        (bytes memory message, bytes memory options) =
            _buildMsgAndOptions(_sendParam, _extraOptions, _composeMsg, amountReceivedLD);
        (msgReceipt, oftReceipt) = _generateReceipt(
            _sendParam.dstEid, message, options, _fee, _refundAddress, amountSentLD, amountReceivedLD
        );
        emit OFTSent(
            msgReceipt.guid,
            msg.sender,
            amountSentLD,
            amountReceivedLD,
            message
        );
    }

    /**
     * @dev Internal function to generate the receipts for a token send operation.
     * @param dstId The destination endpoint identifier.
     * @param message The message to be sent to the destination chain.
     * @param options The options to be used for the messaging operation.
     * @param fee The messaging fee details.
     * @param _refundAddress The address for refunding any excess fees.
     * @param amountDebited The amount of tokens debited from the sender.
     * @param amountCredited The amount of tokens credited to the recipient.
     * @return msgReceipt The receipt of the messaging operation {the costs involved in sending a message, specifying the native token fee and the fee in LayerZero tokens}
     * @return oftReceipt The receipt of the OFT operation 
     */
    function _generateReceipt(
        uint32 dstId,
        bytes memory message,
        bytes memory options,
        MessagingFee calldata fee,
        address _refundAddress,
        uint256 amountDebited,
        uint256 amountCredited
    ) internal returns (MessagingReceipt memory, OFTReceipt memory) {
        MessagingReceipt memory msgReceipt = _lzSend(dstId, message, options, fee, _refundAddress);
        OFTReceipt memory oftReceipt = OFTReceipt(amountDebited, amountCredited);
        return (msgReceipt, oftReceipt);
    }

    /**
     * @dev Internal function to debit tokens from the sender, executes on source chain
     * @param _amount The amount of tokens to debit.
     * @param _minAmount The minimum amount of tokens to debit.
     * @param _dstId The destination endpoint identifier.
     * @return amountSent The amount of tokens sent.
     * @return amountReceived The amount of tokens received.
     */
    function _debit(uint256 _amount, uint256 _minAmount, uint32 _dstId)
        internal
        virtual
        override
        returns (uint256 amountSent, uint256 amountReceived)
    {
        // Internal function to mock the amount mutation from a OFT debit() operation
        // The amount to send in local decimals, The minimum amount to credit in local decimals, The destination endpoint ID.
        // returns: The amount to ACTUALLY debit, in local decimals, The amount to credit on the remote chain, in local decimals.
        /// @dev uses _debitView to handle how many tokens should be debited on the source chain, versus credited on the destination chain
        (amountSent, amountReceived) = _debitView(_amount, _minAmount, _dstId);
        _innerToken.safeTransferFrom(msg.sender, address(this), amountSent);
        _totalReceivedTokens += amountSent;
    }

    /**
     * @dev Internal function to credit tokens to a recipient, executes on destination chain
     * closed_param _to The recipient address.
     * @param amount The amount of tokens to credit.
     * closed_param _srcEid The source endpoint identifier.
     * @return amountReceived The amount of tokens credited.
     */
    function _credit(address to, uint256 amount, uint32 /*srcId*/ )
        internal
        virtual
        override
        returns (uint256 amountReceived)
    {   
        require(to != address(0));
        _innerToken.safeTransfer(to, amount);
        _totalDistribution += amount;
        return amount;
    }

    /// @dev Handles token debiting from the message sender, calculates fees and amounts, verify minimum credit amount requirements and returns both the debited and credited amount
    function _debitSender(uint256 _amountToSendLD, uint256 _minAmountToCreditLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountDebitedLD, uint256 amountToCreditLD)
    {}

    /// @dev Handles token debiting from the bridge contract itself, calculates amounts considering bridge's balance
    function _debitThis(uint256 _minAmountToCreditLD, uint32 _dstEid)
        internal
        virtual
        override
        returns (uint256 amountDebitedLD, uint256 amountToCreditLD)
    {}

    /// @notice Returns the major and minor version of the OFT implementation.
    function oftVersion() external override view returns (uint64 major, uint64 minor) {}
    
    /// @notice Returns the address of the inner token contract.
    function token() external view returns (address) {
        return address(_innerToken);
    }
    
    /// @notice Returns the total supply of the inner token contract.
    function totalSupply() external view returns (uint256) {
        return _innerToken.balanceOf(address(this));
    }
    
    /// @notice Pauses the contract, preventing any token transfers.
    /// @dev Can only be called by the contract owner.
    function pause() external onlyOwner {
        _pause();
    }
    
    /// @notice Unpauses the contract, allowing token transfers again.
    /// @dev Can only be called by the contract owner.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Allows the contract owner to rescue any ERC20 tokens that have been accidentally sent to the contract.
    /// provides emergency withdrawal capabilities for stuck tokens
    /// @param _token The address of the ERC20 token to be rescued.
    /// @param _to The address to which the rescued tokens will be sent.
    /// @param _amount The amount of tokens to be rescued.
    function rescueToken(address _token, address _to, uint256 _amount)
        external
        isValidContract(_token)
        validAddress(_to)
        onlyOwner
    {
        require(_amount > 0);
        SafeERC20.safeTransfer(IERC20(_token), _to, _amount);
        // event
    }
    
    /// @notice Allows the contract owner to withdraw the Ether balance of the contract.
    /// Handles accumulated gas fees or direct native tokens transfers
    function withdraw() external onlyOwner {
        uint256 balance = address(this).balance;
        (bool success,) = payable(msg.sender).call{value: balance}("");
        require(success);
    }
}
