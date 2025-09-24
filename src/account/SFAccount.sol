// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "./interfaces/ISFAccount.sol";
import {IRecoverable} from "./interfaces/IRecoverable.sol";
import {IVault} from "./interfaces/IVault.sol";
import {ISFEngine} from "../token/interfaces/ISFEngine.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

contract SFAccount is ISFAccount, BaseAccount, OwnableUpgradeable, AccessControlUpgradeable, ERC165 {

    using EnumerableSet for EnumerableSet.AddressSet;
    using ERC165Checker for address;

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFAccount__OperationNotSupported();
    error SFAccount__SocialRecoveryNotSupported();
    error SFAccount__OnlyGuardian();
    error SFAccount__TooManyGuardians(uint256 maxGuardians);
    error SfAccount__NotSFAccount(address account);
    error SFAccount__NoPendingRecovery();
    error SFAccount__InsufficientApprovals(uint256 currentApprovals, uint256 requiredApprovals);
    error SFAccount__RecoveryNotExecutable(uint256 executableTime);
    error SFAccount__RecoveryAlreadyInitiated(address newOwner);
    error SFAccount__InvalidTokenAddress(address tokenAddress);
    error SFAccount__InvalidTokenAmount(uint256 tokenAmount);
    error SFAccount__TransferFailed();
    error SFAccount__InsufficientCollateral(address receiver, address collateralAddress, uint256 balance, uint256 required);
    error SFAccount__AccountIsFrozen();
    error SFAccount__AccountIsNotFrozen();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SFAccount__SocialRecoveryEnabled();
    event SFAccount__SocialRecoveryDisabled();
    event SFAccount__GuardianAdded(address indexed guardian);
    event SFAccount__GuardianRemoved(address indexed guardian);
    event SFAccount__MaxGuardiansUpdated(uint8 indexed maxGuardians);
    event SFAccount__MinGuardianApprovalsUpdated(uint8 indexed minGuardianApprovals);
    event SFAccount__RecoveryTimeLockUpdated(uint256 indexed recoveryTimeLock);
    event SFAccount__RecoveryInitiated(address indexed newOwner);
    event SFAccount__RecoveryApproved(address indexed guardian);
    event SFAccount__RecoveryCancelled(address indexed guardian);
    event SFAccount__RecoveryCompleted(address indexed previousOwner, address indexed newOwner);
    event SFAccount__Deposit(address indexed collateralAddress, uint256 indexed amount);
    event SFAccount__Withdraw(address indexed collateralAddress, uint256 indexed amount);
    event SFAccount__AccountFreezed(address indexed freezedBy);
    event SFAccount__AccountUnfreezed(address indexed unfreezedBy);

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

    struct RecoveryRecord {
        bool isCompleted;
        bool isCancelled;
        address cancelledBy;
        address previousOwner;
        address newOwner;
        address[] approvedGuardians;
        uint256 executableTime;
    }

    struct FreezeRecord {
        address freezedBy;
        address unfreezedBy;
        bool isUnfreezed;
    }

    /* -------------------------------------------------------------------------- */
    /*                                  Constants                                 */
    /* -------------------------------------------------------------------------- */

    bytes32 private constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    /// @dev The sfEngine contract used to interact with protocol
    ISFEngine private sfEngine;
    /// @dev The Entry point contract address on current chain
    address private entryPointAddress;
    /// @dev The address of the factory contract which creates this account contract
    address private accountFactoryAddress;
    /// @dev Whether this account supports social recovery
    bool private socialRecoveryEnabled;
    /// @dev Max number of guardians that can be added
    uint8 private maxGuardians;
    /// @dev Minimum amount of guardian approvals needed to recover the current account
    uint8 private minGuardianApprovals;
    /// @dev Guardian addresses for social recovery
    EnumerableSet.AddressSet private guardians;
    /// @dev Social recovery time lock, recovery can only be executed after a delay
    uint256 private recoveryTimeLock;
    /// @dev The recovery records of current account
    RecoveryRecord[] private recoveryRecords;
    /// @dev Whether this account is frozen
    bool private frozen;
    /// @dev The freeze records of current account
    FreezeRecord[] private freezeRecords;

    /* -------------------------------------------------------------------------- */
    /*                                  Modifiers                                 */
    /* -------------------------------------------------------------------------- */

    modifier recoverable() {
        _requireSupportsSocialRecovery();
        _;
    }

    modifier recoverableAccount(address account) {
        _requireSupportsSocialRecovery(account);
        _;
    }

    modifier onlyGuardian() {
        if (!hasRole(GUARDIAN_ROLE, _msgSender())) {
            revert SFAccount__OnlyGuardian();
        }
        _;
    }

    modifier onlySFAccount(address account) {
        _requireSFAccount(account);
        _;
    }

    modifier notFrozen() {
        _requireNotFrozen();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                Initializers                                */
    /* -------------------------------------------------------------------------- */

    function initialize(
        address[] memory _guardians, 
        uint8 _maxGuardians, 
        uint8 _minGuardianApprovals,
        uint256 _recoveryTimeLock,
        address _entryPointAddress,
        address _sfEngineAddress,
        address _accountFactoryAddress
    ) external initializer {
        // Upgradeable init
        __AccessControl_init();
        __Ownable_init(msg.sender);
        // State variable init
        _updateMaxGuardians(_maxGuardians);
        _updateMinGuardianApprovals(_minGuardianApprovals);
        _updateRecoveryTimeLock(_recoveryTimeLock);
        _initializeGuardians(_guardians, _maxGuardians);
        entryPointAddress = _entryPointAddress;
        sfEngine = ISFEngine(_sfEngineAddress);
        accountFactoryAddress = _accountFactoryAddress;
        frozen = false;
        socialRecoveryEnabled = false;
    }

    function reinitialize(
        uint64 _version, 
        uint8 _maxGuardians,
        uint8 _minGuardianApprovals,
        uint256 _recoveryTimeLock
    ) external reinitializer(_version) {
        _updateMaxGuardians(_maxGuardians);
        _updateMinGuardianApprovals(_minGuardianApprovals);
        _updateRecoveryTimeLock(_recoveryTimeLock);
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc IVault
    function invest(
        address collateralTokenAddress,
        uint256 amountCollateral
    ) external override onlyOwner notFrozen {

    }

    /// @inheritdoc IVault
    function harvest(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem
    ) external override onlyOwner notFrozen {

    }

    /// @inheritdoc IVault
    function liquidate(
        address user, 
        address collateralTokenAddress, 
        uint256 debtToCover
    ) external override onlyOwner notFrozen {

    }

    /// @inheritdoc IVault
    function deposit(
        address collateralAddress, 
        uint256 amount
    ) external override onlyOwner notFrozen {
        if (collateralAddress == address(0)) {
            revert SFAccount__InvalidTokenAddress(collateralAddress);
        }
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        bool success = IERC20(collateralAddress).transferFrom(owner(), address(this), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IVault
    function withdraw(
        address collateralAddress, 
        uint256 amount
    ) external override onlyOwner notFrozen {
        if (collateralAddress == address(0)) {
            revert SFAccount__InvalidTokenAddress(collateralAddress);
        }
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        uint256 collateralBalance = getCollateralBalance(collateralAddress);
        if (amount > collateralBalance) {
            if (amount == type(uint256).max) {
                amount = getCollateralBalance(collateralAddress);
            } else {
                revert SFAccount__InsufficientCollateral(owner(), collateralAddress, collateralBalance, amount);
            }
        }
        bool success = IERC20(collateralAddress).transfer(owner(), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
        emit SFAccount__Withdraw(collateralAddress, amount);
    }

    /// @inheritdoc IVault
    function getCollateralBalance(address collateralAddress) public view override returns (uint256) {
        return IERC20(collateralAddress).balanceOf(address(this));
    }

    /// @inheritdoc ISFAccount
    function balance() external override returns (uint256) {

    }

    /// @inheritdoc ISFAccount
    function transfer(address to, uint256 amount) external override onlyOwner notFrozen onlySFAccount(to) {

    }

    function supportsSocialRecovery() public view override returns (bool) {
        return socialRecoveryEnabled;
    }

    /// @inheritdoc IRecoverable
    function enableSocialRecovery() external onlyOwner override {
        socialRecoveryEnabled = true;
        emit SFAccount__SocialRecoveryEnabled();
    }

    /// @inheritdoc IRecoverable
    function disableSocialRecovery() external onlyOwner override {
        socialRecoveryEnabled = false;
        emit SFAccount__SocialRecoveryDisabled();
    }

    /// @inheritdoc IRecoverable
    function initiateRecovery(address account, address newOwner) 
        external 
        override 
        onlyOwner 
        notFrozen 
        onlySFAccount(account)
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryInitiation(newOwner);
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryInitiation(address newOwner) external override onlyGuardian recoverable {
        RecoveryRecord memory pendingRecovery = _getPendingRecovery();
        if (pendingRecovery.previousOwner != address(0)) {
            revert SFAccount__RecoveryAlreadyInitiated(pendingRecovery.newOwner);
        }
        RecoveryRecord memory recoveryRecord = RecoveryRecord({
            isCompleted: false,
            isCancelled: false,
            cancelledBy: address(0),
            previousOwner: owner(),
            newOwner: newOwner,
            approvedGuardians: new address[](0),
            executableTime: block.timestamp + recoveryTimeLock
        });
        recoveryRecords.push(recoveryRecord);
        _freezeAccount(msg.sender);
        emit SFAccount__RecoveryInitiated(newOwner);
    }

    /// @inheritdoc IRecoverable
    function approveRecovery(address account) 
        external 
        override 
        onlyOwner 
        notFrozen 
        onlySFAccount(account) 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryApproval(address(this));
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryApproval(address guardian) external override onlyGuardian recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.approvedGuardians.push(guardian);
        emit SFAccount__RecoveryApproved(guardian);
        bool approvalIsSufficient = recoveryRecord.approvedGuardians.length >= minGuardianApprovals;
        bool executableTimeReached = block.timestamp >= recoveryRecord.executableTime;
        if (approvalIsSufficient && executableTimeReached) {
            _completeRecovery();
        }
    }

    /// @inheritdoc IRecoverable
    function cancelRecovery(address account) 
        external 
        override 
        onlyOwner 
        notFrozen 
        onlySFAccount(account) 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryCancellation(address(this));
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryCancellation(address guardian) external override onlyGuardian recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.isCancelled = true;
        recoveryRecord.cancelledBy = guardian;
        _unFreezeAccount(guardian);
        emit SFAccount__RecoveryCancelled(guardian);
    }

    /// @inheritdoc IRecoverable
    function getRecoveryProgress() external view override recoverable returns (
        bool isInRecoveryProgress, 
        uint256 currentApprovals, 
        uint256 requiredApprovals, 
        uint256 executableTime
    ) {
        RecoveryRecord memory recoveryRecord = _getPendingRecoveryUnchecked();
        if (recoveryRecord.previousOwner == address(0)) {
            isInRecoveryProgress = false;
            return (isInRecoveryProgress, currentApprovals, requiredApprovals, executableTime);
        }
        isInRecoveryProgress = true;
        currentApprovals = recoveryRecord.approvedGuardians.length;
        requiredApprovals = minGuardianApprovals;
        executableTime = recoveryRecord.executableTime;
    }

    /// @inheritdoc IRecoverable
    function getGuardians() external view override recoverable returns (address[] memory) {
        return guardians.values();
    }

    /// @inheritdoc IRecoverable
    function addGuardian(address guardian) public override onlyOwner recoverable notFrozen {
        _requireSFAccount(guardian);
        if (guardians.length() == maxGuardians) {
            revert SFAccount__TooManyGuardians(maxGuardians);
        }
        _grantRole(GUARDIAN_ROLE, guardian);
        guardians.add(guardian);
        emit SFAccount__GuardianAdded(guardian);
    }

    /// @inheritdoc IRecoverable
    function removeGuardian(address guardian) external override onlyOwner recoverable notFrozen {
        _requireSFAccount(guardian);
        _revokeRole(GUARDIAN_ROLE, guardian);
        guardians.remove(guardian);
        emit SFAccount__GuardianRemoved(guardian);
    }

    /// @inheritdoc IRecoverable
    function isGuardian(address account) external view recoverable override returns (bool) {
        return guardians.contains(account);
    }

    /// @inheritdoc ISFAccount
    function freeze() external override onlyOwner {
        _freezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function unfreeze() external override onlyOwner {
        _unFreezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function isFrozen() external view override returns (bool) {
        return frozen;
    }

    /// @inheritdoc BaseAccount
    function entryPoint() public view override returns (IEntryPoint) {
        return IEntryPoint(entryPointAddress);
    }

    /// @inheritdoc BaseAccount
    function execute(address /* target */, uint256 /* value */, bytes calldata /* data */) external pure override {
        revert SFAccount__OperationNotSupported();
    }

    /// @inheritdoc BaseAccount
    function executeBatch(Call[] calldata /* calls */) external pure override {
        revert SFAccount__OperationNotSupported();
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, AccessControlUpgradeable) returns (bool) {
        return interfaceId == type(ISFAccount).interfaceId || super.supportsInterface(interfaceId);
    }

    /* -------------------------------------------------------------------------- */
    /*                        Internal / Private Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc BaseAccount
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal override returns (uint256 validationData) {

    }

    function _initializeGuardians(address[] memory _guardians, uint256 _maxGuardians) private {
        if (_guardians.length > _maxGuardians) {
            revert SFAccount__TooManyGuardians(_maxGuardians);
        }
        for (uint256 i = 0; i < _guardians.length; i++) {
            addGuardian(_guardians[i]);
        }
    }

    function _requireSFAccount(address account) private view {
        if (account == address(0) || !account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert SfAccount__NotSFAccount(account);
        }
    }

    function _requireSupportsSocialRecovery() private view {
        if (!supportsSocialRecovery()) {
            revert SFAccount__SocialRecoveryNotSupported();
        }
    }

    function _requireSupportsSocialRecovery(address account) private view {
        if (!ISFAccount(account).supportsSocialRecovery()) {
            revert SFAccount__SocialRecoveryNotSupported();
        }
    }

    function _updateMaxGuardians(uint8 _maxGuardians) private {
        maxGuardians = _maxGuardians;
        emit SFAccount__MaxGuardiansUpdated(_maxGuardians);
    }

    function _updateMinGuardianApprovals(uint8 _minGuardianApprovals) private {
        minGuardianApprovals = _minGuardianApprovals;
        emit SFAccount__MinGuardianApprovalsUpdated(_minGuardianApprovals);
    }

    function _updateRecoveryTimeLock(uint256 _recoveryTimeLock) private {
        recoveryTimeLock = _recoveryTimeLock;
        emit SFAccount__RecoveryTimeLockUpdated(_recoveryTimeLock);
    }

    function _getPendingRecovery() private view returns (RecoveryRecord storage) {
        if (recoveryRecords.length == 0) {
            revert SFAccount__NoPendingRecovery();
        }
        RecoveryRecord storage latestRecord = recoveryRecords[recoveryRecords.length - 1];
        if (latestRecord.isCompleted || latestRecord.isCancelled) {
            revert SFAccount__NoPendingRecovery();
        }
        return latestRecord;
    }

    function _getPendingRecoveryUnchecked() private view returns (RecoveryRecord memory recoveryRecord) {
        if (recoveryRecords.length == 0) {
            return recoveryRecord;
        }
        RecoveryRecord memory latestRecord = recoveryRecords[recoveryRecords.length - 1];
        return (latestRecord.isCompleted || latestRecord.isCancelled) 
            ? recoveryRecord 
            : latestRecord;
    }

    function _existsPendingRecovery() private view returns (bool) {
        if (recoveryRecords.length == 0) {
            return false;
        }
        RecoveryRecord memory latestRecord = recoveryRecords[recoveryRecords.length - 1];
        return !(latestRecord.isCompleted || latestRecord.isCancelled);
    }

    function _completeRecovery() private {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        uint256 currentApprovals = recoveryRecord.approvedGuardians.length;
        if (currentApprovals < minGuardianApprovals) {
            revert SFAccount__InsufficientApprovals(currentApprovals, minGuardianApprovals);
        }
        if (block.timestamp < recoveryRecord.executableTime) {
            revert SFAccount__RecoveryNotExecutable(recoveryRecord.executableTime);
        }
        recoveryRecord.isCompleted = true;
        _transferOwnership(recoveryRecord.newOwner);
        emit SFAccount__RecoveryCompleted(recoveryRecord.previousOwner, recoveryRecord.newOwner);
    }

    function _freezeAccount(address freezedBy) private notFrozen {
        frozen = true;
        FreezeRecord memory freezeRecord = FreezeRecord({
            freezedBy: freezedBy,
            unfreezedBy: address(0),
            isUnfreezed: false
        });
        freezeRecords.push(freezeRecord);
        emit SFAccount__AccountFreezed(freezedBy);
    }

    function _unFreezeAccount(address unfreezedBy) private {
        _requireFrozen();
        FreezeRecord storage freezeRecord = freezeRecords[freezeRecords.length - 1];
        freezeRecord.isUnfreezed = true;
        freezeRecord.unfreezedBy = unfreezedBy;
        emit SFAccount__AccountUnfreezed(unfreezedBy);
    }

    function _requireNotFrozen() private view {
        if (frozen) {
            revert SFAccount__AccountIsFrozen();
        }
    }

    function _requireFrozen() private view {
        if (!frozen) {
            revert SFAccount__AccountIsNotFrozen();
        }
    }

}