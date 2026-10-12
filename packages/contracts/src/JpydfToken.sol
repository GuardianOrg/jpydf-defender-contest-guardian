// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "./Dependencies/Ownable.sol";
import "./Interfaces/IJpydfToken.sol";

/*
 * --- Functionality added specific to the JpydfToken ---
 *
 * 1) Transfer protection: blacklist of addresses that are invalid recipients (i.e. core Liquity contracts) in external
 * transfer() and transferFrom() calls. The purpose is to protect users from losing tokens by mistakenly sending JPYDF directly to a Liquity
 * core contract, when they should rather call the right function.
 *
 * 2) sendToPool() and returnFromPool(): functions callable only Liquity core contracts, which move JPYDF tokens between Liquity <-> user.
 *
 * 3) Dormant bridge readiness: bridge-specific mint/burn entrypoints gated by an independent bridgeAdmin and
 * bridge minter registry. The existing core mint()/burn() paths remain unchanged.
 */

contract JpydfToken is Ownable, IJpydfToken, ERC20Permit {
    string internal constant _NAME = "JPYdf Stablecoin";
    string internal constant _SYMBOL = "JPYdf";
    uint256 public constant BRIDGE_MINTER_TIMELOCK = 48 hours;

    // --- Addresses ---

    address public collateralRegistryAddress;
    mapping(address => bool) troveManagerAddresses;
    mapping(address => bool) stabilityPoolAddresses;
    mapping(address => bool) borrowerOperationsAddresses;
    mapping(address => bool) activePoolAddresses;

    address public override bridgeAdmin;
    address public override pendingBridgeAdmin;
    address public override proposedBridgeMinter;
    uint256 public override bridgeMinterProposedAt;
    uint256 public override bridgeMinterCount;
    mapping(address => bool) public bridgeMinterAddresses;

    // --- Events ---
    event CollateralRegistryAddressChanged(address _newCollateralRegistryAddress);
    event TroveManagerAddressAdded(address _newTroveManagerAddress);
    event StabilityPoolAddressAdded(address _newStabilityPoolAddress);
    event BorrowerOperationsAddressAdded(address _newBorrowerOperationsAddress);
    event ActivePoolAddressAdded(address _newActivePoolAddress);

    constructor(address _initialOwner, address _bridgeAdmin)
        Ownable(_initialOwner)
        ERC20(_NAME, _SYMBOL)
        ERC20Permit(_NAME)
    {
        if (_initialOwner == address(0)) revert JpydfToken__ZeroOwner();
        if (_bridgeAdmin == address(0)) revert JpydfToken__ZeroBridgeAdmin();
        if (_bridgeAdmin == _initialOwner) revert JpydfToken__BridgeAdminCannotBeOwner();
        _requireBridgeAdminContract(_bridgeAdmin);

        bridgeAdmin = _bridgeAdmin;
        emit BridgeAdminTransferred(address(0), _bridgeAdmin);
    }

    modifier onlyBridgeAdmin() {
        _requireCallerIsBridgeAdmin();
        _;
    }

    function setBranchAddresses(
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _borrowerOperationsAddress,
        address _activePoolAddress
    ) external override onlyOwner {
        _requireCoreContract(_troveManagerAddress);
        _requireCoreContract(_stabilityPoolAddress);
        _requireCoreContract(_borrowerOperationsAddress);
        _requireCoreContract(_activePoolAddress);

        troveManagerAddresses[_troveManagerAddress] = true;
        emit TroveManagerAddressAdded(_troveManagerAddress);

        stabilityPoolAddresses[_stabilityPoolAddress] = true;
        emit StabilityPoolAddressAdded(_stabilityPoolAddress);

        borrowerOperationsAddresses[_borrowerOperationsAddress] = true;
        emit BorrowerOperationsAddressAdded(_borrowerOperationsAddress);

        activePoolAddresses[_activePoolAddress] = true;
        emit ActivePoolAddressAdded(_activePoolAddress);
    }

    function setCollateralRegistry(address _collateralRegistryAddress) external override onlyOwner {
        _requireCoreContract(_collateralRegistryAddress);

        collateralRegistryAddress = _collateralRegistryAddress;
        emit CollateralRegistryAddressChanged(_collateralRegistryAddress);

        _renounceOwnership();
    }

    // --- Bridge readiness ---

    function proposeBridgeMinter(address _bridgeMinter) external override onlyBridgeAdmin {
        if (_bridgeMinter == address(0)) revert JpydfToken__ZeroBridgeMinter();
        if (_bridgeMinter == address(this)) revert JpydfToken__BridgeMinterCannotBeToken();
        if (_bridgeMinter == bridgeAdmin || _bridgeMinter == pendingBridgeAdmin) {
            revert JpydfToken__BridgeMinterCannotBeAdmin();
        }
        if (bridgeMinterAddresses[_bridgeMinter]) revert JpydfToken__BridgeMinterAlreadySet();
        if (proposedBridgeMinter != address(0)) revert JpydfToken__BridgeMinterAlreadyProposed();
        _requireBridgeMinterContract(_bridgeMinter);

        proposedBridgeMinter = _bridgeMinter;
        bridgeMinterProposedAt = block.timestamp;

        emit BridgeMinterProposed(_bridgeMinter, block.timestamp, block.timestamp + BRIDGE_MINTER_TIMELOCK);
    }

    function confirmBridgeMinter() external override onlyBridgeAdmin {
        address bridgeMinter = proposedBridgeMinter;
        if (bridgeMinter == address(0)) revert JpydfToken__NoBridgeMinterProposed();
        if (bridgeMinter == bridgeAdmin || bridgeMinter == pendingBridgeAdmin) {
            revert JpydfToken__BridgeMinterCannotBeAdmin();
        }
        _requireBridgeMinterContract(bridgeMinter);
        if (block.timestamp < bridgeMinterProposedAt + BRIDGE_MINTER_TIMELOCK) {
            revert JpydfToken__BridgeMinterTimelockNotElapsed();
        }

        bridgeMinterAddresses[bridgeMinter] = true;
        bridgeMinterCount++;
        delete proposedBridgeMinter;
        delete bridgeMinterProposedAt;

        emit BridgeMinterConfirmed(bridgeMinter);
    }

    function cancelBridgeMinterProposal() external override onlyBridgeAdmin {
        address bridgeMinter = proposedBridgeMinter;
        if (bridgeMinter == address(0)) revert JpydfToken__NoBridgeMinterProposed();

        delete proposedBridgeMinter;
        delete bridgeMinterProposedAt;

        emit BridgeMinterProposalCancelled(bridgeMinter);
    }

    function removeBridgeMinter(address _bridgeMinter) external override onlyBridgeAdmin {
        if (!bridgeMinterAddresses[_bridgeMinter]) revert JpydfToken__NotBridgeMinter();

        bridgeMinterAddresses[_bridgeMinter] = false;
        bridgeMinterCount--;

        emit BridgeMinterRemoved(_bridgeMinter);
    }

    function transferBridgeAdmin(address _newBridgeAdmin) external override onlyBridgeAdmin {
        if (_newBridgeAdmin == address(0)) revert JpydfToken__ZeroBridgeAdmin();
        if (_newBridgeAdmin == address(this)) revert JpydfToken__BridgeAdminCannotBeToken();
        if (_newBridgeAdmin == owner()) revert JpydfToken__BridgeAdminCannotBeOwner();
        if (bridgeMinterAddresses[_newBridgeAdmin] || _newBridgeAdmin == proposedBridgeMinter) {
            revert JpydfToken__BridgeAdminCannotBeMinter();
        }
        _requireBridgeAdminContract(_newBridgeAdmin);

        pendingBridgeAdmin = _newBridgeAdmin;

        emit BridgeAdminTransferStarted(bridgeAdmin, _newBridgeAdmin);
    }

    function acceptBridgeAdmin() external override {
        if (msg.sender != pendingBridgeAdmin) revert JpydfToken__CallerIsNotPendingBridgeAdmin();
        if (bridgeMinterAddresses[msg.sender] || msg.sender == proposedBridgeMinter) {
            revert JpydfToken__BridgeAdminCannotBeMinter();
        }
        _requireBridgeAdminContract(msg.sender);

        address previousBridgeAdmin = bridgeAdmin;
        bridgeAdmin = msg.sender;
        delete pendingBridgeAdmin;

        emit BridgeAdminTransferred(previousBridgeAdmin, msg.sender);
    }

    function renounceBridgeAdmin() external override onlyBridgeAdmin {
        if (bridgeMinterCount != 0) revert JpydfToken__BridgeMintersStillSet();
        if (proposedBridgeMinter != address(0)) revert JpydfToken__CannotRenounceWithPendingBridgeMinter();

        address previousBridgeAdmin = bridgeAdmin;
        delete bridgeAdmin;
        delete pendingBridgeAdmin;

        emit BridgeAdminTransferred(previousBridgeAdmin, address(0));
    }

    function isBridgeMinter(address _account) external view override returns (bool) {
        return bridgeMinterAddresses[_account];
    }

    // --- Functions for intra-Liquity calls ---

    function mint(address _account, uint256 _amount) external override {
        _requireCallerIsBOorAP();
        _mint(_account, _amount);
    }

    function burn(address _account, uint256 _amount) external override {
        _requireCallerIsCRorBOorTMorSP();
        _burn(_account, _amount);
    }

    function bridgeMint(address _account, uint256 _amount) external override {
        _requireCallerIsBridgeMinter();
        _requireValidRecipient(_account);
        _mint(_account, _amount);
        emit BridgeMint(msg.sender, _account, _amount);
    }

    function bridgeBurn(uint256 _amount) external override {
        _requireCallerIsBridgeMinter();
        _burn(msg.sender, _amount);
        emit BridgeBurn(msg.sender, _amount);
    }

    function isValidRecipient(address _recipient) external view override returns (bool) {
        return _isValidRecipient(_recipient);
    }

    function requireValidRecipient(address _recipient) external view override {
        _requireValidRecipient(_recipient);
    }

    function sendToPool(address _sender, address _poolAddress, uint256 _amount) external override {
        _requireCallerIsStabilityPool();
        _transfer(_sender, _poolAddress, _amount);
    }

    function returnFromPool(address _poolAddress, address _receiver, uint256 _amount) external override {
        _requireCallerIsStabilityPool();
        _transfer(_poolAddress, _receiver, _amount);
    }

    // --- External functions ---

    function transfer(address recipient, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        _requireValidRecipient(recipient);
        return super.transfer(recipient, amount);
    }

    function transferFrom(address sender, address recipient, uint256 amount)
        public
        override(ERC20, IERC20)
        returns (bool)
    {
        _requireValidRecipient(recipient);
        return super.transferFrom(sender, recipient, amount);
    }

    // --- 'require' functions ---

    function _requireValidRecipient(address _recipient) internal view {
        if (!_isValidRecipient(_recipient)) revert JpydfToken__CannotTransferToProtocolContract();
    }

    function _isValidRecipient(address _recipient) internal view returns (bool) {
        return _recipient != address(0) && _recipient != address(this) && _recipient != collateralRegistryAddress
            && !troveManagerAddresses[_recipient] && !stabilityPoolAddresses[_recipient]
            && !borrowerOperationsAddresses[_recipient] && !activePoolAddresses[_recipient];
    }

    function _requireCallerIsBOorAP() internal view {
        if (!(borrowerOperationsAddresses[msg.sender] || activePoolAddresses[msg.sender])) {
            revert JpydfToken__CallerIsNotBorrowerOperationsOrActivePool();
        }
    }

    function _requireCallerIsCRorBOorTMorSP() internal view {
        if (
            msg.sender != collateralRegistryAddress && !borrowerOperationsAddresses[msg.sender]
                && !troveManagerAddresses[msg.sender] && !stabilityPoolAddresses[msg.sender]
        ) revert JpydfToken__CallerIsNotCoreBurner();
    }

    function _requireCallerIsStabilityPool() internal view {
        if (!stabilityPoolAddresses[msg.sender]) revert JpydfToken__CallerIsNotStabilityPool();
    }

    function _requireCallerIsBridgeAdmin() internal view {
        if (msg.sender != bridgeAdmin) revert JpydfToken__CallerIsNotBridgeAdmin();
    }

    function _requireCallerIsBridgeMinter() internal view {
        if (!bridgeMinterAddresses[msg.sender]) revert JpydfToken__CallerIsNotBridgeMinter();
    }

    function _requireCoreContract(address _account) internal view {
        if (_account == address(0)) revert JpydfToken__ZeroCoreAddress();
        if (_account.code.length == 0) revert JpydfToken__CoreAddressMustBeContract();
    }

    function _requireBridgeAdminContract(address _account) internal view {
        if (_account.code.length == 0) revert JpydfToken__BridgeAdminMustBeContract();
    }

    function _requireBridgeMinterContract(address _account) internal view {
        if (_account.code.length == 0) revert JpydfToken__BridgeMinterMustBeContract();
    }
}
