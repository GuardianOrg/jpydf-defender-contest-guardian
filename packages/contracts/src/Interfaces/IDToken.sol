// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20MetadataUpgradeable.sol";
import "openzeppelin-contracts-upgradeable/token/ERC20/extensions/IERC20PermitUpgradeable.sol";

/**
 * @title IDToken - Collateral Benefit Token Interface
 * @notice ERC-20 token representing a 1:1 principal claim on Underlying
 * @dev decimals fixed at 18 (per Liquity v2 requirements)
 */
interface IDToken is IERC20MetadataUpgradeable, IERC20PermitUpgradeable {
    /// @notice Corresponding Underlying token
    function underlying() external view returns (IERC20MetadataUpgradeable);

    /// @notice Vault address that issues this dToken
    function vault() external view returns (address);

    /// @notice Underlying token decimals
    function underlyingDecimals() external view returns (uint8);

    /// @notice Maximum supply cap for dToken
    function cap() external view returns (uint256);

    /// @notice Whether an underlying token is allowed for this dToken.
    function allowedUnderlying(address _underlying) external view returns (bool);

    /**
     * @notice Convert UnderlyingAmount to dTokenAmount
     * @param _underlyingAmount Amount of Underlying
     * @return dTokenAmount amount (18 decimals)
     */
    function convertToDToken(uint256 _underlyingAmount) external view returns (uint256);

    /**
     * @notice Convert dTokenAmount to UnderlyingAmount
     * @param _dTokenAmount dToken amount (18 decimals)
     * @return underlyingAmount amount
     */
    function convertToUnderlying(uint256 _dTokenAmount) external view returns (uint256);

    /**
     * @notice Mint dToken (Vault only)
     * @param _to Recipient address
     * @param _amount Mint amount
     * @dev Reverts if cap is exceeded
     */
    function mint(address _to, uint256 _amount) external;

    /**
     * @notice Burn dToken (Vault only)
     * @param _from Address to burn from
     * @param _amount Burn amount
     */
    function burn(address _from, uint256 _amount) external;

    /**
     * @notice Set the maximum supply cap for dToken (Admin only)
     * @param _newCap New cap value (18 decimals)
     */
    function setCap(uint256 _newCap) external;

    /**
     * @notice Allow or disallow an underlying asset before token info is bound (Admin only)
     * @param _underlying Underlying token address
     * @param _allowed Whether the token is allowed
     */
    function setAllowedUnderlying(address _underlying, bool _allowed) external;

    /**
     * @notice Set token name, symbol, and underlying asset (Admin only)
     * @param _newName Token name
     * @param _newSymbol Token symbol
     * @param _underlying Corresponding Underlying token
     */
    function setTokenInfo(string memory _newName, string memory _newSymbol, IERC20MetadataUpgradeable _underlying)
        external;
}
