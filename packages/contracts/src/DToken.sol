// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.8.24;

import "openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/Initializable.sol";
import "openzeppelin-contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/access/OwnableUpgradeable.sol";

import "./Interfaces/IDToken.sol";
import {IAddressesRegistry} from "src/Interfaces/IAddressesRegistry.sol";

/**
 * @title DToken - Collateral Benefit Token (Upgradeable)
 * @notice ERC-20 token representing a 1:1 principal claim on Underlying
 * @dev - decimals fixed at 18 (per Liquity v2 requirements)
 *      - mint/burn permissions restricted to CollateralVault only
 *      - EIP-2612 permit support (enables redeem without prior approve)
 *      - No yield accrual (principal claim only)
 *      - Upgradeable via UUPS pattern
 */
contract DToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable,
    IDToken
{
    /// @notice Corresponding Underlying token
    IERC20MetadataUpgradeable public override underlying;

    /// @notice Vault address that issues this dToken
    address public override vault;

    /// @notice Fixed decimals for dToken
    uint8 public constant DTOKEN_DECIMALS = 18;

    /// @notice Underlying token decimals
    uint8 public override underlyingDecimals;

    /// @notice Custom name for dToken, set after initialization
    string private _customName;

    /// @notice Custom symbol for dToken, set after initialization
    string private _customSymbol;

    /// @notice Multiplier for decimals conversion (10^(18 - underlyingDecimals))
    uint256 private _decimalMultiplier;

    /// @notice Maximum supply cap for dToken
    /// @dev 18 decimals. Starts closed until the branch's risk parameters are final.
    uint256 public override cap;

    /// @notice Pending owner for two-step ownership transfer
    address private _pendingOwner;

    /// @notice Underlying tokens allowed for this dToken binding.
    mapping(address => bool) public override allowedUnderlying;

    /// @notice One-shot binding to the Core branch that controls mint readiness.
    address public override riskParamsRegistry;

    /// @dev Storage gap for future upgrades. See OpenZeppelin's storage gap guidance:
    /// https://docs.openzeppelin.com/upgrades-plugins/writing-upgradeable#storage-gaps
    /// Always append new storage variables above this gap and shrink the gap
    /// instead of inserting variables between existing storage slots.
    uint256[47] private __gap;

    // --- Errors ---

    /// @notice Address cannot be zero
    error ZeroAddress();

    /// @notice Mint/burn called from non-Vault address
    error OnlyVault();

    /// @notice Underlying decimals exceeds 18
    error InvalidUnderlyingDecimals();

    /// @notice Address must be a deployed contract
    error NotContract();

    /// @notice Underlying token has not been allowlisted
    error UnderlyingNotAllowed();

    /// @notice Total supply after mint exceeds cap
    error CapExceeded(uint256 totalSupplyAfterMint, uint256 cap);

    /// @notice Token info already set
    error TokenInfoAlreadySet();

    /// @notice Token name cannot be empty
    error EmptyTokenName();

    /// @notice Token symbol cannot be empty
    error EmptyTokenSymbol();

    /// @notice Token info cannot be changed after supply exists
    error SupplyAlreadyExists();

    /// @notice Token info has not been configured yet
    error TokenInfoNotSet();

    /// @notice Ownership renounce is disabled to preserve governance controls
    error RenounceOwnershipDisabled();

    error DToken__RiskParamsNotFinalized();
    error DToken__RiskParamsRegistryAlreadySet();
    error DToken__RegistryCollateralMismatch();
    error DToken__CapMustBeZero();

    // --- Events ---

    /// @notice Emitted when cap is updated
    event CapUpdated(uint256 oldCap, uint256 newCap);

    event RiskParamsRegistryBound(address indexed registry);

    /// @notice Emitted when token metadata and underlying asset are configured
    event TokenInfoSet(string name, string symbol, address indexed underlying, uint8 underlyingDecimals);

    /// @notice Emitted when an underlying token allowlist entry is updated
    event AllowedUnderlyingUpdated(address indexed underlying, bool allowed);

    /// @notice Emitted when an ownership transfer is started
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    // --- Modifiers ---

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    // --- Constructor (for implementation) ---

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- Initializer ---

    /**
     * @notice dToken initialization function
     * @param _vault Vault address that issues this dToken
     * @param _owner Owner with upgrade permissions
     */
    function initialize(address _vault, address _owner) external initializer {
        if (_vault == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        // Initialize with placeholders. Values will be set later via setTokenInfo.
        __ERC20_init("DToken Placeholder", "dTOKEN");
        __ERC20Permit_init("DToken Placeholder");
        __Ownable_init();
        __UUPSUpgradeable_init();

        _transferOwnership(_owner);

        vault = _vault;
    }

    /**
     * @notice Set token name, symbol, and underlying asset
     * @dev Can only be called once by the owner.
     * @param _newName Token name (e.g., "dWBTC")
     * @param _newSymbol Token symbol (e.g., "dWBTC")
     * @param _underlying Corresponding Underlying token
     */
    function setTokenInfo(string memory _newName, string memory _newSymbol, IERC20MetadataUpgradeable _underlying)
        external
        onlyOwner
    {
        if (address(underlying) != address(0)) revert TokenInfoAlreadySet();
        if (address(_underlying) == address(0)) revert ZeroAddress();
        if (bytes(_newName).length == 0) revert EmptyTokenName();
        if (bytes(_newSymbol).length == 0) revert EmptyTokenSymbol();
        if (totalSupply() != 0) revert SupplyAlreadyExists();

        address underlyingAddress = address(_underlying);
        if (underlyingAddress.code.length == 0) revert NotContract();
        if (!allowedUnderlying[underlyingAddress]) revert UnderlyingNotAllowed();

        // Bind `underlying` before the external decimals() call below so a reentrant
        // setTokenInfo() is rejected by the TokenInfoAlreadySet check above (one-shot
        // guard). The remaining state is written only after decimals validation passes.
        underlying = _underlying;

        uint8 _underlyingDecimals = _underlying.decimals();
        if (_underlyingDecimals > DTOKEN_DECIMALS) revert InvalidUnderlyingDecimals();

        _customName = _newName;
        _customSymbol = _newSymbol;
        underlyingDecimals = _underlyingDecimals;
        _decimalMultiplier = 10 ** (DTOKEN_DECIMALS - _underlyingDecimals);

        emit TokenInfoSet(_newName, _newSymbol, address(_underlying), _underlyingDecimals);
    }

    // --- UUPS Upgrade Authorization ---

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // --- Ownership Overrides ---

    /**
     * @notice Pending owner for two-step ownership transfer.
     */
    function pendingOwner() public view returns (address) {
        return _pendingOwner;
    }

    /**
     * @notice Start a two-step ownership transfer.
     * @dev Passing address(0) cancels an existing pending transfer, matching
     *      OpenZeppelin Ownable2Step behavior.
     */
    function transferOwnership(address newOwner) public override onlyOwner {
        _pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /**
     * @notice Accept a pending ownership transfer.
     */
    function acceptOwnership() public {
        require(_pendingOwner == _msgSender(), "Ownable2Step: caller is not the new owner");
        _transferOwnership(_msgSender());
    }

    /**
     * @notice Disable ownership renounce to avoid permanently bricking cap,
     *         token-info, and upgrade governance.
     */
    function renounceOwnership() public view override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function _transferOwnership(address newOwner) internal override {
        delete _pendingOwner;
        super._transferOwnership(newOwner);
    }

    // --- ERC20 Overrides ---

    /**
     * @notice Returns the name of the token.
     */
    function name() public view override(ERC20Upgradeable, IERC20MetadataUpgradeable) returns (string memory) {
        return bytes(_customName).length > 0 ? _customName : super.name();
    }

    /**
     * @notice Returns the symbol of the token.
     */
    function symbol() public view override(ERC20Upgradeable, IERC20MetadataUpgradeable) returns (string memory) {
        return bytes(_customSymbol).length > 0 ? _customSymbol : super.symbol();
    }

    /**
     * @notice dToken decimals is always 18
     * @dev Liquity v2 assumes collateral tokens have 18 decimals
     */
    function decimals() public pure override(ERC20Upgradeable, IERC20MetadataUpgradeable) returns (uint8) {
        return DTOKEN_DECIMALS;
    }

    /**
     * @notice EIP-712 domain name for permit signatures.
     * @dev Binds the EIP-712 DOMAIN_SEPARATOR to the live token name() (set via setTokenInfo)
     *      instead of the constructor-time placeholder. Standard wallets/frontends build the
     *      permit domain from `name()`, so without this the on-chain separator (placeholder)
     *      and the off-chain signature (real name) would diverge and permit() would revert.
     *
     *      Safe on OpenZeppelin Contracts (upgradeable) v4.9: EIP712Upgradeable does NOT cache
     *      the domain separator for proxies — `_domainSeparatorV4()` rebuilds it from
     *      `_EIP712NameHash()` = keccak256(_EIP712Name()) on every call — so overriding
     *      `_EIP712Name()` here propagates to both DOMAIN_SEPARATOR() and eip712Domain()
     *      with no extra storage, gap change, or re-initialization. setTokenInfo() is one-shot
     *      and gated on totalSupply()==0, so the name is final before any holder can sign a permit.
     */
    function _EIP712Name() internal view virtual override returns (string memory) {
        return name();
    }

    // --- Vault-Only Functions ---

    /**
     * @notice Mint dToken
     * @dev Callable by Vault only. Reverts if cap is exceeded
     * @param _to Recipient address
     * @param _amount Mint amount (18 decimals)
     */
    function mint(address _to, uint256 _amount) external override onlyVault {
        // Underlying must be bound (via setTokenInfo) before any mint. Otherwise a
        // mint while unbound would push totalSupply() > 0 and permanently brick
        // setTokenInfo() (SupplyAlreadyExists), stranding the dToken at placeholder
        // metadata with reverting conversions. Enforces "no mint before bind" on-chain.
        if (address(underlying) == address(0)) revert TokenInfoNotSet();
        _requireRiskParamsFinalized();
        uint256 newTotalSupply = totalSupply() + _amount;
        if (newTotalSupply > cap) {
            revert CapExceeded(newTotalSupply, cap);
        }
        _mint(_to, _amount);
    }

    /**
     * @notice Burn dToken
     * @dev Callable by Vault only
     * @param _from Address to burn from
     * @param _amount Burn amount (18 decimals)
     */
    function burn(address _from, uint256 _amount) external override onlyVault {
        _burn(_from, _amount);
    }

    // --- Conversion Functions ---

    /**
     * @notice Convert UnderlyingAmount to dTokenAmount
     * @dev Converts Underlying decimals to 18 decimals
     * @param _underlyingAmount Amount in Underlying (underlyingDecimals)
     * @return dTokenAmount amount (18 decimals)
     */
    function convertToDToken(uint256 _underlyingAmount) external view override returns (uint256) {
        if (_decimalMultiplier == 0) revert TokenInfoNotSet();
        return _underlyingAmount * _decimalMultiplier;
    }

    /**
     * @notice Convert dTokenAmount to UnderlyingAmount
     * @dev Converts 18 decimals to Underlying decimals
     * @param _dTokenAmount dToken amount (18 decimals)
     * @return underlyingAmount amount (underlyingDecimals)
     */
    function convertToUnderlying(uint256 _dTokenAmount) external view override returns (uint256) {
        if (_decimalMultiplier == 0) revert TokenInfoNotSet();
        return _dTokenAmount / _decimalMultiplier;
    }

    // --- View Functions ---

    /**
     * @notice Override of nonces function
     */
    function nonces(address owner)
        public
        view
        override(ERC20PermitUpgradeable, IERC20PermitUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    // --- Admin Functions ---

    /**
     * @notice Set the maximum supply cap for dToken
     * @dev Callable by Owner only (admin privilege)
     * @param _newCap New cap value (18 decimals)
     */
    function setCap(uint256 _newCap) external override onlyOwner {
        if (_newCap != 0) _requireRiskParamsFinalized();
        uint256 oldCap = cap;
        cap = _newCap;
        emit CapUpdated(oldCap, _newCap);
    }

    /// @inheritdoc IDToken
    function setRiskParamsRegistry(address _registry) external override onlyOwner {
        if (riskParamsRegistry != address(0)) revert DToken__RiskParamsRegistryAlreadySet();
        if (_registry.code.length == 0) revert NotContract();
        if (cap != 0) revert DToken__CapMustBeZero();
        if (totalSupply() != 0) revert SupplyAlreadyExists();
        if (address(IAddressesRegistry(_registry).collToken()) != address(this)) {
            revert DToken__RegistryCollateralMismatch();
        }
        riskParamsRegistry = _registry;
        emit RiskParamsRegistryBound(_registry);
    }

    function _requireRiskParamsFinalized() internal view {
        address registry = riskParamsRegistry;
        if (registry == address(0) || !IAddressesRegistry(registry).riskParamsFinalized()) {
            revert DToken__RiskParamsNotFinalized();
        }
    }

    /**
     * @notice Allow or disallow an underlying asset before `setTokenInfo`.
     * @dev Mainnet deployments should allowlist exactly the intended token
     *      contract for this dToken (for example the canonical USDC address)
     *      before binding metadata. EOA / predeploy addresses are rejected.
     */
    function setAllowedUnderlying(address _underlying, bool _allowed) external override onlyOwner {
        if (_underlying == address(0)) revert ZeroAddress();
        if (address(underlying) != address(0)) revert TokenInfoAlreadySet();
        if (_underlying.code.length == 0) revert NotContract();

        allowedUnderlying[_underlying] = _allowed;
        emit AllowedUnderlyingUpdated(_underlying, _allowed);
    }
}
