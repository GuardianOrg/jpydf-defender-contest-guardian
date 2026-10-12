// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/security/ReentrancyGuard.sol";

import {IInitiative} from "src/Interfaces/IInitiative.sol";
import {IJpydfToken} from "src/Interfaces/IJpydfToken.sol";

/**
 * @title PILAllocator
 * @notice Admin-weighted Phase-A allocator for PIL JPYdf liquidity incentives.
 * @custom:security-contact security@deltaforesight.xyz
 */
contract PILAllocator is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_INITIATIVES = 32;
    uint256 internal constant MIN_GAS_TO_HOOK = 350_000;

    IERC20 public immutable jpydfToken;
    uint256 public immutable EPOCH_START;
    uint256 public immutable EPOCH_DURATION;
    uint256 public immutable MIN_DISTRIBUTE;

    address public owner;
    address public pendingOwner;
    address public guardian;
    bool public paused;
    uint256 public totalWeight;

    address[] internal _initiatives;
    mapping(address => bool) public registeredInitiatives;
    mapping(address => uint256) public initiativeIndexPlusOne;
    mapping(address => uint256) public weightOf;

    event InitiativeRegistered(address indexed initiative, uint256 atEpoch, bool hookSucceeded);
    event InitiativeUnregistered(address indexed initiative, uint256 atEpoch, bool hookSucceeded);
    event WeightsUpdated(address[] initiatives, uint256[] weights);
    event Distributed(address indexed initiative, uint256 amount, uint256 indexed epoch, bool hookSucceeded);
    event Paused();
    event Unpaused();
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error PILAllocator__ZeroAddress();
    error PILAllocator__EpochStartInFuture();
    error PILAllocator__ZeroEpochDuration();
    error PILAllocator__ZeroMinDistribute();
    error PILAllocator__DurationTooLarge();
    error PILAllocator__Unauthorized();
    error PILAllocator__AlreadyRegistered(address initiative);
    error PILAllocator__NotRegistered(address initiative);
    error PILAllocator__DuplicateInitiative(address initiative);
    error PILAllocator__LengthMismatch();
    error PILAllocator__InvalidTotalWeight(uint256 totalWeight);
    error PILAllocator__Paused();
    error PILAllocator__RenounceOwnershipDisabled();
    error PILAllocator__InvalidJpydfRecipient(address initiative);
    error PILAllocator__InitiativeHasWeight(address initiative, uint256 weight);
    error PILAllocator__DependencyNotContract(address dependency);
    error PILAllocator__InsufficientGasForHook();
    error PILAllocator__TooManyInitiatives(uint256 maxInitiatives);

    modifier onlyOwner() {
        if (msg.sender != owner) revert PILAllocator__Unauthorized();
        _;
    }

    constructor(
        IJpydfToken _jpydfToken,
        uint256 _epochStart,
        uint256 _epochDuration,
        uint256 _minDistribute,
        address _owner,
        address _guardian
    ) {
        if (address(_jpydfToken) == address(0)) revert PILAllocator__ZeroAddress();
        if (_owner == address(0)) revert PILAllocator__ZeroAddress();
        if (_guardian == address(0)) revert PILAllocator__ZeroAddress();
        if (address(_jpydfToken).code.length == 0) {
            revert PILAllocator__DependencyNotContract(address(_jpydfToken));
        }
        if (_epochStart > block.timestamp) revert PILAllocator__EpochStartInFuture();
        if (_epochDuration == 0) revert PILAllocator__ZeroEpochDuration();
        if (_minDistribute == 0) revert PILAllocator__ZeroMinDistribute();
        if (_epochDuration > type(uint32).max) revert PILAllocator__DurationTooLarge();

        jpydfToken = IERC20(address(_jpydfToken));
        EPOCH_START = _epochStart;
        EPOCH_DURATION = _epochDuration;
        MIN_DISTRIBUTE = _minDistribute;
        owner = _owner;
        guardian = _guardian;

        emit OwnershipTransferred(address(0), _owner);
        emit GuardianUpdated(address(0), _guardian);
    }

    /*//////////////////////////////////////////////////////////////
                  USER-FACING STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function registerInitiative(address _initiative) external nonReentrant onlyOwner {
        if (_initiative == address(0)) revert PILAllocator__ZeroAddress();
        if (registeredInitiatives[_initiative]) revert PILAllocator__AlreadyRegistered(_initiative);
        if (_initiatives.length >= MAX_INITIATIVES) revert PILAllocator__TooManyInitiatives(MAX_INITIATIVES);
        _requireValidJpydfRecipient(_initiative);

        registeredInitiatives[_initiative] = true;
        initiativeIndexPlusOne[_initiative] = _initiatives.length + 1;
        _initiatives.push(_initiative);

        uint256 currentEpoch = epoch();
        bool hookSucceeded = _safeCallWithMinGas(
            _initiative, MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onRegisterInitiative, (currentEpoch))
        );

        emit InitiativeRegistered(_initiative, currentEpoch, hookSucceeded);
    }

    function unregisterInitiative(address _initiative) external nonReentrant onlyOwner {
        if (!registeredInitiatives[_initiative]) revert PILAllocator__NotRegistered(_initiative);
        uint256 weight = weightOf[_initiative];
        if (weight != 0) revert PILAllocator__InitiativeHasWeight(_initiative, weight);

        delete weightOf[_initiative];
        registeredInitiatives[_initiative] = false;
        _removeInitiative(_initiative);

        uint256 currentEpoch = epoch();
        bool hookSucceeded = _safeCallWithMinGas(
            _initiative, MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onUnregisterInitiative, (currentEpoch))
        );

        emit InitiativeUnregistered(_initiative, currentEpoch, hookSucceeded);
    }

    function setWeights(address[] calldata _initiativesToSet, uint256[] calldata _weights) external onlyOwner {
        if (_initiativesToSet.length != _weights.length) revert PILAllocator__LengthMismatch();
        _requireNoDuplicates(_initiativesToSet);

        uint256 newTotalWeight = totalWeight;
        for (uint256 i; i < _initiativesToSet.length; ++i) {
            address initiative = _initiativesToSet[i];
            if (!registeredInitiatives[initiative]) revert PILAllocator__NotRegistered(initiative);

            newTotalWeight = newTotalWeight - weightOf[initiative] + _weights[i];
            weightOf[initiative] = _weights[i];
        }
        if (newTotalWeight != 0 && newTotalWeight != WAD) {
            revert PILAllocator__InvalidTotalWeight(newTotalWeight);
        }

        totalWeight = newTotalWeight;
        emit WeightsUpdated(_initiativesToSet, _weights);
    }

    function distribute() external nonReentrant returns (uint256 total) {
        if (paused) revert PILAllocator__Paused();

        uint256 balance = jpydfToken.balanceOf(address(this));
        if (balance < MIN_DISTRIBUTE || totalWeight == 0 || _initiatives.length == 0) return 0;

        uint256 currentEpoch = epoch();
        for (uint256 i; i < _initiatives.length; ++i) {
            address initiative = _initiatives[i];
            uint256 weight = weightOf[initiative];
            if (weight == 0) continue;

            uint256 amount = balance * weight / WAD;
            if (amount == 0) continue;

            total += amount;
            jpydfToken.safeTransfer(initiative, amount);
            bool hookSucceeded = _safeCallWithMinGas(
                initiative, MIN_GAS_TO_HOOK, 0, abi.encodeCall(IInitiative.onClaimForInitiative, (currentEpoch, amount))
            );

            emit Distributed(initiative, amount, currentEpoch, hookSucceeded);
        }
    }

    function pause() external {
        if (msg.sender != guardian) revert PILAllocator__Unauthorized();

        paused = true;
        emit Paused();
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused();
    }

    function setGuardian(address _newGuardian) external onlyOwner {
        if (_newGuardian == address(0)) revert PILAllocator__ZeroAddress();

        address oldGuardian = guardian;
        guardian = _newGuardian;
        emit GuardianUpdated(oldGuardian, _newGuardian);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        pendingOwner = _newOwner;
        emit OwnershipTransferStarted(owner, _newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert PILAllocator__Unauthorized();

        address oldOwner = owner;
        owner = msg.sender;
        delete pendingOwner;
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    function renounceOwnership() external view onlyOwner {
        revert PILAllocator__RenounceOwnershipDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                    USER-FACING READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function epoch() public view returns (uint256) {
        return ((block.timestamp - EPOCH_START) / EPOCH_DURATION) + 1;
    }

    function epochStart() public view returns (uint256) {
        return EPOCH_START + (epoch() - 1) * EPOCH_DURATION;
    }

    function initiatives() external view returns (address[] memory) {
        return _initiatives;
    }

    function initiativeCount() external view returns (uint256) {
        return _initiatives.length;
    }

    function initiativeAt(uint256 _index) external view returns (address) {
        return _initiatives[_index];
    }

    function pendingDistributable() external view returns (uint256 amount) {
        amount = jpydfToken.balanceOf(address(this));
        if (amount < MIN_DISTRIBUTE || totalWeight == 0 || _initiatives.length == 0) return 0;
        amount = amount * totalWeight / WAD;
    }

    /*//////////////////////////////////////////////////////////////
                    INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _removeInitiative(address _initiative) internal {
        uint256 indexPlusOne = initiativeIndexPlusOne[_initiative];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _initiatives.length - 1;

        if (index != lastIndex) {
            address lastInitiative = _initiatives[lastIndex];
            _initiatives[index] = lastInitiative;
            initiativeIndexPlusOne[lastInitiative] = index + 1;
        }

        _initiatives.pop();
        delete initiativeIndexPlusOne[_initiative];
    }

    function _safeCallWithMinGas(address _target, uint256 _gas, uint256 _value, bytes memory _calldata)
        internal
        returns (bool success)
    {
        if (!_hasMinGas(_gas, 1_000)) revert PILAllocator__InsufficientGasForHook();

        assembly {
            success := call(_gas, _target, _value, add(_calldata, 0x20), mload(_calldata), 0, 0)
        }
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _requireValidJpydfRecipient(address _initiative) internal view {
        try IJpydfToken(address(jpydfToken)).requireValidRecipient(_initiative) {}
        catch {
            revert PILAllocator__InvalidJpydfRecipient(_initiative);
        }
    }

    function _requireNoDuplicates(address[] calldata _initiativesToSet) internal pure {
        for (uint256 i; i < _initiativesToSet.length; ++i) {
            for (uint256 j = i + 1; j < _initiativesToSet.length; ++j) {
                if (_initiativesToSet[i] == _initiativesToSet[j]) {
                    revert PILAllocator__DuplicateInitiative(_initiativesToSet[i]);
                }
            }
        }
    }

    function _hasMinGas(uint256 _minGas, uint256 _reservedGas) internal view returns (bool hasEnoughGas) {
        assembly {
            hasEnoughGas := iszero(lt(mul(gas(), 63), add(mul(_minGas, 64), mul(add(40000, _reservedGas), 63))))
        }
    }
}
