// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "../interfaces/ISFAccount.sol";
import {IRecoverable} from "../interfaces/IRecoverable.sol";
import {IVault} from "../interfaces/IVault.sol";
import {ISFEngine} from "../interfaces/ISFEngine.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";

contract SFAccount is ISFAccount, BaseAccount, AutomationCompatible, OwnableUpgradeable, AccessControlUpgradeable, ERC165 {

    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ERC165Checker for address;
    using Arrays for address[];

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFAccount__OperationNotSupported();
    error SFAccount__CollateralNotSupported(address collateral);
    error SFAccount__MismatchBetweenCollateralAndPriceFeeds(
        uint256 numCollaterals, 
        uint256 numPriceFeeds
    );
    error SFAccount__CollateralRatioIsTooLow(uint256 minCollateralRatio);
    error SFAccount__TopUpNotNeeded(
        uint256 currentCollateralInUsd, 
        uint256 requiredCollateralInUsd, 
        uint256 targetCollateralRatio
    );
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
    error SFAccount__InsufficientCollateral(
        address receiver, 
        address collateralTokenAddress, 
        uint256 balance, 
        uint256 required
    );
    error SFAccount__InsufficientBalance(address receiver, uint256 balance, uint256 required);
    error SFAccount__AccountIsFrozen();
    error SFAccount__AccountIsNotFrozen();

    /* -------------------------------------------------------------------------- */
    /*                                   Events                                   */
    /* -------------------------------------------------------------------------- */

    event SFAccount__CollateralAndPriceFeedUpdated(uint256 indexed numCollateral);
    event SFAccount__Invest(
        address indexed collateralTokenAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );
    event SFAccount__Harvest(
        address indexed collateralTokenAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToBurn
    );
    event SFAccount__Liquidate(
        address indexed account, 
        address indexed collateralTokenAddress, 
        uint256 indexed debtToCover
    );
    event SFAccount__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );
    event SFAccount__TopUpCollateral(
        address indexed collateralTokenAddress, 
        uint256 indexed amountCollateral
    );
    event SFAccount__CollateralRatioMaintained(
        uint256 indexed collateralTopedUpInUsd, 
        uint256 indexed targetCollateralRatio
    );
    event SFAccount__InsufficientCollateralForTopUp(
        uint256 indexed requiredCollateralInUsd, 
        uint256 indexed currentCollateralRatio, 
        uint256 indexed targetCollateralRatio
    );
    event SFAccount__UpdateAutoTopUpSupport(bool indexed enabled);
    event SFAccount__UpdateSocialRecoverySupport(bool indexed enabled);
    event SFAccount__GuardianAdded(address indexed guardian);
    event SFAccount__GuardianRemoved(address indexed guardian);
    event SFAccount__CustomCollateralRatioUpdated(uint256 indexed collateralRatio);
    event SFAccount__MaxGuardiansUpdated(uint8 indexed maxGuardians);
    event SFAccount__MinGuardianApprovalsUpdated(uint8 indexed minGuardianApprovals);
    event SFAccount__RecoveryTimeLockUpdated(uint256 indexed recoveryTimeLock);
    event SFAccount__RecoveryInitiated(address indexed newOwner);
    event SFAccount__RecoveryApproved(address indexed guardian);
    event SFAccount__RecoveryCancelled(address indexed guardian);
    event SFAccount__RecoveryCompleted(address indexed previousOwner, address indexed newOwner);
    event SFAccount__Deposit(address indexed collateralTokenAddress, uint256 indexed amount);
    event SFAccount__Withdraw(address indexed collateralTokenAddress, uint256 indexed amount);
    event SFAccount__AddNewCollateral(address indexed collateralTokenAddress);
    event SFAccount__RemoveCollateral(address indexed collateralTokenAddress);
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
        uint256 totalGuardians;
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

    /// @dev The guardian role
    bytes32 private constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    /// @dev Precision factor used to calculate
    uint256 private constant PRECISION_FACTOR = 1e18;

    /* -------------------------------------------------------------------------- */
    /*                               State Variables                              */
    /* -------------------------------------------------------------------------- */

    /// @dev Supported collateral and its price feed
    mapping(address collateral => address priceFeed) private supportedCollaterals;
    /// @dev The sfEngine contract used to interact with protocol
    ISFEngine private sfEngine;
    /// @dev Address of SFToken contract
    address private sfTokenAddress;
    /// @dev The Entry point contract address on current chain
    address private entryPointAddress;
    /// @dev The address of the factory contract which creates this account contract
    address private accountFactoryAddress;
    /// @dev The address set of deposited token contract address
    EnumerableSet.AddressSet private depositedCollaterals;
    /// @dev The collateral ration used to invest, must be greater than or equal to the minimum collateral ratio supported by SFEngine
    uint256 private customCollateralRatio;
    /// @dev Whether this account supports collateral auto top up
    bool private autoTopUpEnabled;
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

    modifier onlyEntryPoint() {
        _requireFromEntryPoint();
        _;
    }

    modifier requireSupportedCollateral(address collateral) {
        _requireSupportedCollateral(collateral);
        _;
    }

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
        address[] memory collaterals,
        address[] memory priceFeeds,
        uint256 _customCollateralRatio,
        bool _autoTopUpEnabled,
        bool _socialRecoveryEnabled,
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
        _updateSupportedCollaterals(collaterals, priceFeeds);
        _updateCustomCollateralRatio(_customCollateralRatio);
        _updateAutoTopUpSupport(_autoTopUpEnabled);
        _updateSocialRecoverySupport(_socialRecoveryEnabled);
        _updateMaxGuardians(_maxGuardians);
        _updateMinGuardianApprovals(_minGuardianApprovals);
        _updateRecoveryTimeLock(_recoveryTimeLock);
        _initializeGuardians(_guardians, _maxGuardians);
        entryPointAddress = _entryPointAddress;
        sfEngine = ISFEngine(_sfEngineAddress);
        sfTokenAddress = sfEngine.getSFTokenAddress();
        accountFactoryAddress = _accountFactoryAddress;
        frozen = false;
        socialRecoveryEnabled = false;
    }

    function reinitialize(
        address[] memory collaterals,
        address[] memory priceFeeds,
        uint256 _customCollateralRatio,
        uint64 _version, 
        uint8 _maxGuardians,
        uint8 _minGuardianApprovals,
        uint256 _recoveryTimeLock
    ) external reinitializer(_version) {
        _updateSupportedCollaterals(collaterals, priceFeeds);
        _updateCustomCollateralRatio(_customCollateralRatio);
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
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralTokenAddress)
    {
        uint256 collateralBalance = _getCollateralBalance(collateralTokenAddress);
        if (collateralBalance < amountCollateral) {
            revert SFAccount__InsufficientCollateral(
                address(sfEngine), 
                collateralTokenAddress, 
                collateralBalance, 
                amountCollateral
            );
        }
        uint256 amountSFToMint = sfEngine.calculateSFTokensByCollateral(
            collateralTokenAddress, 
            amountCollateral,
            customCollateralRatio
        );
        emit SFAccount__Invest(collateralTokenAddress, amountCollateral, amountSFToMint);
        IERC20(collateralTokenAddress).approve(address(sfEngine), amountCollateral);
        sfEngine.depositCollateralAndMintSFToken(collateralTokenAddress, amountCollateral, amountSFToMint);
    }

    /// @inheritdoc IVault
    function harvest(
        address collateralTokenAddress,
        uint256 amountCollateralToRedeem
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralTokenAddress)
    {
        uint256 amountSFToBurn = sfEngine.calculateSFTokensByCollateral(
            collateralTokenAddress, 
            amountCollateralToRedeem,
            customCollateralRatio
        );
        uint256 sfBalance = _getSFTokenBalance();
        if (amountSFToBurn > sfBalance) {
            revert SFAccount__InsufficientBalance(address(0), sfBalance, amountSFToBurn);
        }
        emit SFAccount__Harvest(collateralTokenAddress, amountCollateralToRedeem, amountSFToBurn);
        sfEngine.redeemCollateral(collateralTokenAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    /// @inheritdoc IVault
    function liquidate(
        address account, 
        address collateralTokenAddress, 
        uint256 debtToCover
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        onlySFAccount(account) 
        requireSupportedCollateral(collateralTokenAddress)
    {
        uint256 sfBalance = _getSFTokenBalance();
        if (debtToCover > sfBalance) {
            revert SFAccount__InsufficientBalance(address(0), sfBalance, debtToCover);
        }
        emit SFAccount__Liquidate(account, collateralTokenAddress, debtToCover);
        IERC20(sfTokenAddress).approve(address(sfEngine), debtToCover);
        sfEngine.liquidate(account, collateralTokenAddress, debtToCover);
    }

    /// @inheritdoc IVault
    function checkCollateralSafety() external view override returns (
        bool danger, 
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        return _checkCollateralSafety();
    }

    /// @inheritdoc IVault
    function topUpCollateral(address collateralTokenAddress, uint256 amount)
        external 
        override 
        onlyEntryPoint 
        requireSupportedCollateral(collateralTokenAddress)
    {
        _topUpCollateral(collateralTokenAddress, amount);
    }

    /// @inheritdoc IVault
    function updateAutoTopUpSupport(bool enabled) external override onlyEntryPoint {
        _updateAutoTopUpSupport(enabled);
    }

    /// @inheritdoc IVault
    function deposit(
        address collateralTokenAddress, 
        uint256 amount
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralTokenAddress)
    {
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        bool added = depositedCollaterals.add(collateralTokenAddress);
        if (added) {
            emit SFAccount__AddNewCollateral(collateralTokenAddress);
        }
        emit SFAccount__Deposit(collateralTokenAddress, amount);
        bool success = IERC20(collateralTokenAddress).transferFrom(owner(), address(this), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IVault
    function withdraw(
        address collateralTokenAddress, 
        uint256 amount
    ) external override onlyEntryPoint notFrozen {
        if (collateralTokenAddress == address(0)) {
            revert SFAccount__InvalidTokenAddress(collateralTokenAddress);
        }
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        uint256 collateralBalance = getCollateralBalance(collateralTokenAddress);
        if (amount > collateralBalance) {
            if (amount == type(uint256).max) {
                amount = getCollateralBalance(collateralTokenAddress);
            } else {
                revert SFAccount__InsufficientCollateral(owner(), collateralTokenAddress, collateralBalance, amount);
            }
        }
        if (amount == collateralBalance) {
            bool removed = depositedCollaterals.remove(collateralTokenAddress);
            if (removed) {
                emit SFAccount__RemoveCollateral(collateralTokenAddress);
            }
        }
        emit SFAccount__Withdraw(collateralTokenAddress, amount);
        bool success = IERC20(collateralTokenAddress).transfer(owner(), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IVault
    function getCollateralBalance(address collateralTokenAddress) public view override returns (uint256) {
        return _getCollateralBalance(collateralTokenAddress);
    }

    /// @inheritdoc IVault
    function getCustomCollateralRatio() external view override returns (uint256) {
        return customCollateralRatio;
    }
    
    /// @inheritdoc IVault
    function getDepositedCollaterals() external view override returns (address[] memory) {
        return depositedCollaterals.values();
    }

    /// @inheritdoc ISFAccount
    function balance() external view override returns (uint256) {
        return _getSFTokenBalance();
    }

    /// @inheritdoc ISFAccount
    function transfer(address to, uint256 amount) external override onlyEntryPoint notFrozen onlySFAccount(to) {
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        bool success = IERC20(sfTokenAddress).transfer(to, amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IRecoverable
    function supportsSocialRecovery() public view override returns (bool) {
        return socialRecoveryEnabled;
    }

    /// @inheritdoc IRecoverable
    function updateSocialRecoverySupport(bool enabled) external override onlyEntryPoint {
        _updateSocialRecoverySupport(enabled);
    }

    /// @inheritdoc IRecoverable
    function initiateRecovery(address account, address newOwner) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryInitiation(newOwner);
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryInitiation(address newOwner) external override onlyGuardian notFrozen recoverable {
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
            totalGuardians: guardians.length(),
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
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryApproval();
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryApproval() external override onlyGuardian notFrozen recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.approvedGuardians.push(msg.sender);
        emit SFAccount__RecoveryApproved(msg.sender);
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
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryCancellation();
    }

    /// @inheritdoc IRecoverable
    function receiveRecoveryCancellation() external override onlyGuardian notFrozen recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.isCancelled = true;
        recoveryRecord.cancelledBy = msg.sender;
        _unFreezeAccount(msg.sender);
        emit SFAccount__RecoveryCancelled(msg.sender);
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
    function addGuardian(address guardian) public override onlyEntryPoint recoverable notFrozen {
        _requireSFAccount(guardian);
        if (guardians.length() == maxGuardians) {
            revert SFAccount__TooManyGuardians(maxGuardians);
        }
        _grantRole(GUARDIAN_ROLE, guardian);
        guardians.add(guardian);
        emit SFAccount__GuardianAdded(guardian);
    }

    /// @inheritdoc IRecoverable
    function removeGuardian(address guardian) external override onlyEntryPoint recoverable notFrozen {
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
    function freeze() external override onlyEntryPoint {
        _freezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function unfreeze() external override onlyEntryPoint {
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

    /// @inheritdoc AutomationCompatibleInterface
    function checkUpkeep(bytes calldata /* checkData */) external override returns (
        bool upkeepNeeded, 
        bytes memory performData
    ) {
        if (autoTopUpEnabled) {
            (bool danger, uint256 collateralRatio, uint256 liquidationThreshold) = _checkCollateralSafety();
            if (danger) {
                upkeepNeeded = true;
                emit SFAccount__Danger(collateralRatio, liquidationThreshold);
                return (upkeepNeeded, performData);
            }
        }
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /* performData */) external override {
        _topUpToMaintainCollateralRatio(sfEngine.getMinimumCollateralRatio());
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

    function _checkCollateralSafety() private view returns (
        bool danger,
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        liquidationThreshold = sfEngine.getMinimumCollateralRatio();
        collateralRatio = sfEngine.getCollateralRatio(address(this));
        if (collateralRatio < liquidationThreshold) {
            danger = true;
        }
    }

    function _topUpCollateral(address collateralTokenAddress, uint256 amount) private {
        uint256 collateralBalance = _getCollateralBalance(collateralTokenAddress);
        if (collateralBalance < amount) {
            revert SFAccount__InsufficientCollateral(
                address(sfEngine), 
                collateralTokenAddress, 
                collateralBalance, 
                amount
            );
        }
        emit SFAccount__TopUpCollateral(collateralTokenAddress, amount);
        IERC20(collateralTokenAddress).approve(address(sfEngine), amount);
        sfEngine.depositCollateralAndMintSFToken(collateralTokenAddress, amount, 0);
    }

    function _topUpToMaintainCollateralRatio(uint256 targetCollateralRatio) private {
        uint256 sfTokenBalance = _getSFTokenBalance();
        uint256 currentCollateralInUsd = sfEngine.getTotalCollateralValueInUsd(address(this));
        uint256 requiredCollateralInUsd = sfTokenBalance * targetCollateralRatio / PRECISION_FACTOR;
        if (currentCollateralInUsd >= requiredCollateralInUsd) {
            revert SFAccount__TopUpNotNeeded(currentCollateralInUsd, requiredCollateralInUsd, targetCollateralRatio);
        }
        uint256 collateralToTopUpInUsd = requiredCollateralInUsd - currentCollateralInUsd;
        address[] memory collaterals = depositedCollaterals.values();
        for (uint256 i = 0; i < collaterals.length && collateralToTopUpInUsd > 0; i++) {
            address priceFeed = supportedCollaterals[collaterals[i]];
            if (priceFeed == address(0)) {
                continue;
            }
            uint256 collateralBalance = _getCollateralBalance(collaterals[i]);
            uint256 collateralBalanceInUsd = AggregatorV3Interface(priceFeed).getTokenValue(collateralBalance);
            uint256 amountCollateralToTopUp;
            if (collateralBalanceInUsd >= collateralToTopUpInUsd) {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(collateralToTopUpInUsd);
                collateralToTopUpInUsd = 0;
            } else {
                amountCollateralToTopUp = AggregatorV3Interface(priceFeed).getTokensForValue(collateralBalanceInUsd);
                collateralToTopUpInUsd -= collateralBalanceInUsd;
            }
            _topUpCollateral(collaterals[i], amountCollateralToTopUp);
        }
        if (collateralToTopUpInUsd > 0) {
            uint256 currentCollateralRatio = requiredCollateralInUsd * PRECISION_FACTOR / sfTokenBalance;
            emit SFAccount__InsufficientCollateralForTopUp(
                collateralToTopUpInUsd,
                currentCollateralRatio,
                targetCollateralRatio
            );
        }
        emit SFAccount__CollateralRatioMaintained(collateralToTopUpInUsd, targetCollateralRatio);
    }

    function _updateSupportedCollaterals(
        address[] memory collaterals, 
        address[] memory priceFeeds
    ) private {
        if (collaterals.length != priceFeeds.length) {
            revert SFAccount__MismatchBetweenCollateralAndPriceFeeds(
                collaterals.length, 
                priceFeeds.length
            );
        }
        for (uint256 i = 0; i < collaterals.length; i++) {
            supportedCollaterals[collaterals[i]] = priceFeeds[i];
        }
        emit SFAccount__CollateralAndPriceFeedUpdated(collaterals.length);
    }

    function _initializeGuardians(address[] memory _guardians, uint256 _maxGuardians) private {
        if (_guardians.length > _maxGuardians) {
            revert SFAccount__TooManyGuardians(_maxGuardians);
        }
        for (uint256 i = 0; i < _guardians.length; i++) {
            addGuardian(_guardians[i]);
        }
    }

    function _requireSupportedCollateral(address collateral) private view {
        if (supportedCollaterals[collateral] == address(0)) {
            revert SFAccount__CollateralNotSupported(collateral);
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
        _requireSFAccount(account);
        if (!ISFAccount(account).supportsSocialRecovery()) {
            revert SFAccount__SocialRecoveryNotSupported();
        }
    }

    function _updateCustomCollateralRatio(uint256 collateralRatio) private {
        uint256 minCollateralRatio = sfEngine.getMinimumCollateralRatio();
        if (customCollateralRatio < minCollateralRatio) {
            revert SFAccount__CollateralRatioIsTooLow(minCollateralRatio);
        }
        customCollateralRatio = collateralRatio;
        emit SFAccount__CustomCollateralRatioUpdated(collateralRatio);
    }

    function _updateAutoTopUpSupport(bool enabled) private {
        autoTopUpEnabled = enabled;
        emit SFAccount__UpdateAutoTopUpSupport(enabled);
    }

    function _updateSocialRecoverySupport(bool enabled) private {
        socialRecoveryEnabled = enabled;
        emit SFAccount__UpdateSocialRecoverySupport(enabled);
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

    function _freezeAccount(address freezedBy) private {
        _requireNotFrozen();
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

    function _getCollateralBalance(address collateralTokenAddress) private view returns (uint256) {
        return IERC20(collateralTokenAddress).balanceOf(address(this));
    }

    function _getSFTokenBalance() private view returns (uint256) {
        return IERC20(sfTokenAddress).balanceOf(address(this));
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