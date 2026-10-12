// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import "openzeppelin-contracts/contracts/interfaces/IERC5267.sol";

interface IJpydfToken is IERC20Metadata, IERC20Permit, IERC5267 {
    error JpydfToken__ZeroOwner();
    error JpydfToken__ZeroBridgeAdmin();
    error JpydfToken__BridgeAdminCannotBeOwner();
    error JpydfToken__BridgeAdminCannotBeToken();
    error JpydfToken__BridgeAdminCannotBeMinter();
    error JpydfToken__BridgeAdminMustBeContract();
    error JpydfToken__CallerIsNotBridgeAdmin();
    error JpydfToken__CallerIsNotPendingBridgeAdmin();
    error JpydfToken__ZeroBridgeMinter();
    error JpydfToken__BridgeMinterCannotBeToken();
    error JpydfToken__BridgeMinterCannotBeAdmin();
    error JpydfToken__BridgeMinterAlreadySet();
    error JpydfToken__BridgeMinterAlreadyProposed();
    error JpydfToken__NoBridgeMinterProposed();
    error JpydfToken__BridgeMinterMustBeContract();
    error JpydfToken__BridgeMinterTimelockNotElapsed();
    error JpydfToken__NotBridgeMinter();
    error JpydfToken__BridgeMintersStillSet();
    error JpydfToken__CannotRenounceWithPendingBridgeMinter();
    error JpydfToken__CallerIsNotBridgeMinter();
    error JpydfToken__ZeroCoreAddress();
    error JpydfToken__CoreAddressMustBeContract();
    error JpydfToken__CannotTransferToProtocolContract();
    error JpydfToken__CallerIsNotBorrowerOperationsOrActivePool();
    error JpydfToken__CallerIsNotCoreBurner();
    error JpydfToken__CallerIsNotStabilityPool();

    event BridgeAdminTransferStarted(address indexed currentBridgeAdmin, address indexed pendingBridgeAdmin);
    event BridgeAdminTransferred(address indexed previousBridgeAdmin, address indexed newBridgeAdmin);
    event BridgeMinterProposed(address indexed bridgeMinter, uint256 proposedAt, uint256 confirmableAt);
    event BridgeMinterProposalCancelled(address indexed bridgeMinter);
    event BridgeMinterConfirmed(address indexed bridgeMinter);
    event BridgeMinterRemoved(address indexed bridgeMinter);
    event BridgeMint(address indexed bridgeMinter, address indexed account, uint256 amount);
    event BridgeBurn(address indexed bridgeMinter, uint256 amount);

    function setBranchAddresses(
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _borrowerOperationsAddress,
        address _activePoolAddress
    ) external;

    function setCollateralRegistry(address _collateralRegistryAddress) external;

    function mint(address _account, uint256 _amount) external;

    function burn(address _account, uint256 _amount) external;

    function bridgeAdmin() external view returns (address);

    function pendingBridgeAdmin() external view returns (address);

    function proposedBridgeMinter() external view returns (address);

    function bridgeMinterProposedAt() external view returns (uint256);

    function bridgeMinterCount() external view returns (uint256);

    function isBridgeMinter(address _account) external view returns (bool);

    function proposeBridgeMinter(address _bridgeMinter) external;

    function confirmBridgeMinter() external;

    function cancelBridgeMinterProposal() external;

    function removeBridgeMinter(address _bridgeMinter) external;

    function transferBridgeAdmin(address _newBridgeAdmin) external;

    function acceptBridgeAdmin() external;

    function renounceBridgeAdmin() external;

    function bridgeMint(address _account, uint256 _amount) external;

    function bridgeBurn(uint256 _amount) external;

    function isValidRecipient(address _recipient) external view returns (bool);

    function requireValidRecipient(address _recipient) external view;

    function sendToPool(address _sender, address poolAddress, uint256 _amount) external;

    function returnFromPool(address poolAddress, address user, uint256 _amount) external;
}
