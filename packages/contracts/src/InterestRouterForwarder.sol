// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IJpydfToken} from "./Interfaces/IJpydfToken.sol";

/**
 * @title InterestRouterForwarder
 * @notice Mutable recipient shim for ActivePool's immutable `interestRouter`.
 * @dev ActivePool only mints the non-SP interest share to `interestRouter`; it never
 *      calls a hook. This contract therefore holds minted JPYdf until anyone calls
 *      `route()`, then forwards the full balance to the current recipient.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract InterestRouterForwarder {
    using SafeERC20 for IERC20;

    IERC20 public immutable jpydfToken;

    address public owner;
    address public pendingOwner;
    address public recipient;

    event Routed(address indexed recipient, uint256 amount);
    event RecipientUpdated(address indexed oldRecipient, address indexed newRecipient);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error ZeroAddress();
    error Unauthorized();
    error RenounceOwnershipDisabled();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(IERC20 _jpydfToken, address _recipient, address _owner) {
        if (address(_jpydfToken) == address(0)) revert ZeroAddress();
        if (_recipient == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();
        IJpydfToken(address(_jpydfToken)).requireValidRecipient(_recipient);

        jpydfToken = _jpydfToken;
        recipient = _recipient;
        owner = _owner;

        emit RecipientUpdated(address(0), _recipient);
        emit OwnershipTransferred(address(0), _owner);
    }

    function route() external returns (uint256 amount) {
        amount = jpydfToken.balanceOf(address(this));
        if (amount == 0) return 0;

        jpydfToken.safeTransfer(recipient, amount);
        emit Routed(recipient, amount);
    }

    function setRecipient(address _newRecipient) external onlyOwner {
        if (_newRecipient == address(0)) revert ZeroAddress();
        IJpydfToken(address(jpydfToken)).requireValidRecipient(_newRecipient);

        address oldRecipient = recipient;
        recipient = _newRecipient;
        emit RecipientUpdated(oldRecipient, _newRecipient);
    }

    /// @notice Starts a 2-step ownership transfer. Passing address(0) cancels a pending transfer.
    function transferOwnership(address _newOwner) external onlyOwner {
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();

        address oldOwner = owner;
        owner = msg.sender;
        delete pendingOwner;
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function renounceOwnership() external view onlyOwner {
        revert RenounceOwnershipDisabled();
    }
}
