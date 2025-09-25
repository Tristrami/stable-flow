// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {ISFAccount} from "../interfaces/ISFAccount.sol";
import {ISocialRecoveryPlugin} from "../interfaces/ISocialRecoveryPlugin.sol";
import {IVaultPlugin} from "../interfaces/IVaultPlugin.sol";
import {ISFEngine} from "../interfaces/ISFEngine.sol";
import {AddressArrays} from "../libraries/AddressArrays.sol";
import {OracleLib, AggregatorV3Interface} from "../libraries/OracleLib.sol";
import {BaseAccount} from "account-abstraction/contracts/core/BaseAccount.sol";
import {SIG_VALIDATION_SUCCESS, SIG_VALIDATION_FAILED} from "account-abstraction/contracts/core/Helpers.sol";
import {IEntryPoint} from "account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {AutomationCompatible} from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

contract SFAccount is ISFAccount, BaseAccount, AutomationCompatible, OwnableUpgradeable, AccessControlUpgradeable, ERC165 {

    using AddressArrays for address[];
    using OracleLib for AggregatorV3Interface;
    using EnumerableSet for EnumerableSet.AddressSet;
    using ERC165Checker for address;

    /* -------------------------------------------------------------------------- */
    /*                                   Errors                                   */
    /* -------------------------------------------------------------------------- */

    error SFAccount__NotFromFactory();
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
    error SFAccount__SocialRecoveryIsAlreadyDisabled();
    error SFAccount__SocialRecoveryIsAlreadyEnabled();
    error SFAccount__ApprovalExceedsGuardianAmount(uint256 approvals, uint256 numGuardians);
    error SFAccount__AccountIsInRecoveryProcess();
    error SFAccount__NoGuardianSet();
    error SFAccount__MinGuardianApprovalsIsNotSet();
    error SFAccount__MinGuardianApprovalsCanNotBeZero();
    error SFAccount__OnlyGuardian();
    error SFAccount__TooManyGuardians(uint256 maxGuardians);
    error SFAccount__GuardianAlreadyExists(address guardian);
    error SFAccount__GuardianNotExists(address guardian);
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
        address collateralAddress, 
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
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToMint
    );
    event SFAccount__Harvest(
        address indexed collateralAddress, 
        uint256 indexed amountCollateral, 
        uint256 indexed sfToBurn
    );
    event SFAccount__Liquidate(
        address indexed account, 
        address indexed collateralAddress, 
        uint256 indexed debtToCover
    );
    event SFAccount__Danger(
        uint256 indexed currentCollateralRatio, 
        uint256 indexed liquidatingCollateralRatio
    );
    event SFAccount__TopUpCollateral(
        address indexed collateralAddress, 
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
    event SFAccount__UpdateCustomRecoveryConfig(bool indexed enabled, bytes configData);
    event SFAccount__UpdateCustomAutoTopUpConfig(bool indexed enabled, bytes configData);
    event SFAccount__CustomCollateralRatioUpdated(uint256 indexed collateralRatio);
    event SFAccount__RecoveryInitiated(address indexed newOwner);
    event SFAccount__RecoveryApproved(address indexed guardian);
    event SFAccount__RecoveryCancelled(address indexed guardian);
    event SFAccount__RecoveryCompleted(address indexed previousOwner, address indexed newOwner);
    event SFAccount__Deposit(address indexed collateralAddress, uint256 indexed amount);
    event SFAccount__Withdraw(address indexed collateralAddress, uint256 indexed amount);
    event SFAccount__AddNewCollateral(address indexed collateralAddress);
    event SFAccount__RemoveCollateral(address indexed collateralAddress);
    event SFAccount__AccountFreezed(address indexed freezedBy);
    event SFAccount__AccountUnfreezed(address indexed unfreezedBy);

    /* -------------------------------------------------------------------------- */
    /*                                    Types                                   */
    /* -------------------------------------------------------------------------- */

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

    /// @dev Social recovery config
    RecoveryConfig private recoveryConfig;
    /// @dev Auto top up config
    AutoTopUpConfig private autoTopUpConfig;
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

    modifier notRecovering() {
        _requireNotRecovering();
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
        address _accountOwner,
        address[] memory _collaterals,
        address[] memory _priceFeeds,
        uint256 _customCollateralRatio,
        address _entryPointAddress,
        address _sfEngineAddress,
        address _accountFactoryAddress,
        AutoTopUpConfig memory _autoTopUpConfig,
        RecoveryConfig memory _recoveryConfig
    ) external initializer {
        // Upgradeable init
        __AccessControl_init();
        __Ownable_init(_accountOwner);
        // State variable init
        _updateSupportedCollaterals(_collaterals, _priceFeeds);
        _updateCustomCollateralRatio(_customCollateralRatio);
        autoTopUpConfig = _autoTopUpConfig;
        recoveryConfig = _recoveryConfig;
        entryPointAddress = _entryPointAddress;
        sfEngine = ISFEngine(_sfEngineAddress);
        sfTokenAddress = sfEngine.getSFTokenAddress();
        accountFactoryAddress = _accountFactoryAddress;
        frozen = false;
    }

    function reinitialize(
        address[] memory collaterals,
        address[] memory priceFeeds,
        uint256 _customCollateralRatio,
        uint64 _version, 
        uint8 _maxGuardians
    ) external reinitializer(_version) {
        _updateSupportedCollaterals(collaterals, priceFeeds);
        _updateCustomCollateralRatio(_customCollateralRatio);
        recoveryConfig.maxGuardians = _maxGuardians;
    }

    /* -------------------------------------------------------------------------- */
    /*                         External / Public Functions                        */
    /* -------------------------------------------------------------------------- */

    /// @inheritdoc IVaultPlugin
    function invest(
        address collateralAddress,
        uint256 amountCollateral
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (collateralBalance < amountCollateral) {
            revert SFAccount__InsufficientCollateral(
                address(sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amountCollateral
            );
        }
        uint256 amountSFToMint = sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            amountCollateral,
            customCollateralRatio
        );
        emit SFAccount__Invest(collateralAddress, amountCollateral, amountSFToMint);
        IERC20(collateralAddress).approve(address(sfEngine), amountCollateral);
        sfEngine.depositCollateralAndMintSFToken(collateralAddress, amountCollateral, amountSFToMint);
    }

    /// @inheritdoc IVaultPlugin
    function harvest(
        address collateralAddress,
        uint256 amountCollateralToRedeem
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        uint256 amountSFToBurn = sfEngine.calculateSFTokensByCollateral(
            collateralAddress, 
            amountCollateralToRedeem,
            customCollateralRatio
        );
        uint256 sfBalance = _getSFTokenBalance();
        if (amountSFToBurn > sfBalance) {
            revert SFAccount__InsufficientBalance(address(0), sfBalance, amountSFToBurn);
        }
        emit SFAccount__Harvest(collateralAddress, amountCollateralToRedeem, amountSFToBurn);
        sfEngine.redeemCollateral(collateralAddress, amountCollateralToRedeem, amountSFToBurn);
    }

    /// @inheritdoc IVaultPlugin
    function liquidate(
        address account, 
        address collateralAddress, 
        uint256 debtToCover
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        onlySFAccount(account) 
        requireSupportedCollateral(collateralAddress)
    {
        uint256 sfBalance = _getSFTokenBalance();
        if (debtToCover > sfBalance) {
            revert SFAccount__InsufficientBalance(address(0), sfBalance, debtToCover);
        }
        emit SFAccount__Liquidate(account, collateralAddress, debtToCover);
        IERC20(sfTokenAddress).approve(address(sfEngine), debtToCover);
        sfEngine.liquidate(account, collateralAddress, debtToCover);
    }

    /// @inheritdoc IVaultPlugin
    function updateCustomAutoTopUpConfig(CustomAutoTopUpConfig memory customConfig) external override onlyEntryPoint {
        _updateCustomAutoTopUpConfig(customConfig);
    }

    /// @inheritdoc IVaultPlugin
    function getCustomAutoTopUpConfig() external view override returns (CustomAutoTopUpConfig memory customConfig) {
        return autoTopUpConfig.customConfig;
    }

    /// @inheritdoc IVaultPlugin
    function checkCollateralSafety() external view override returns (
        bool danger, 
        uint256 collateralRatio, 
        uint256 liquidationThreshold
    ) {
        return _checkCollateralSafety();
    }

    /// @inheritdoc IVaultPlugin
    function topUpCollateral(address collateralAddress, uint256 amount)
        external 
        override 
        onlyEntryPoint 
        requireSupportedCollateral(collateralAddress)
    {
        _topUpCollateral(collateralAddress, amount);
    }

    /// @inheritdoc IVaultPlugin
    function deposit(
        address collateralAddress, 
        uint256 amount
    ) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        requireSupportedCollateral(collateralAddress)
    {
        if (amount == 0) {
            revert SFAccount__InvalidTokenAmount(amount);
        }
        bool added = depositedCollaterals.add(collateralAddress);
        if (added) {
            emit SFAccount__AddNewCollateral(collateralAddress);
        }
        emit SFAccount__Deposit(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transferFrom(owner(), address(this), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function withdraw(
        address collateralAddress, 
        uint256 amount
    ) external override onlyEntryPoint notFrozen {
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
        if (amount == collateralBalance) {
            bool removed = depositedCollaterals.remove(collateralAddress);
            if (removed) {
                emit SFAccount__RemoveCollateral(collateralAddress);
            }
        }
        emit SFAccount__Withdraw(collateralAddress, amount);
        bool success = IERC20(collateralAddress).transfer(owner(), amount);
        if (!success) {
            revert SFAccount__TransferFailed();
        }
    }

    /// @inheritdoc IVaultPlugin
    function getCollateralBalance(address collateralAddress) public view override returns (uint256) {
        return _getCollateralBalance(collateralAddress);
    }

    /// @inheritdoc IVaultPlugin
    function getCustomCollateralRatio() external view override returns (uint256) {
        return customCollateralRatio;
    }
    
    /// @inheritdoc IVaultPlugin
    function getDepositedCollaterals() external view override returns (address[] memory) {
        return depositedCollaterals.values();
    }

    /// @inheritdoc ISFAccount
    function getOwner() external view override returns (address) {
        return owner();
    }

    /// @inheritdoc ISFAccount
    function debt() external view override returns (uint256) {
        return _getSFDebt();
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

    /// @inheritdoc ISFAccount
    function freeze() external override onlyEntryPoint {
        _freezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function unfreeze() external override onlyEntryPoint {
        _unfreezeAccount(owner());
    }

    /// @inheritdoc ISFAccount
    function isFrozen() external view override returns (bool) {
        return frozen;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function supportsSocialRecovery() public view override returns (bool) {
        return _supportsSocialRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) external override onlyEntryPoint {
        _updateCustomRecoveryConfig(customConfig);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getCustomRecoveryConfig() external view override returns (CustomRecoveryConfig memory customConfig) {
        return recoveryConfig.customConfig;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function initiateRecovery(address account, address newOwner) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveRecoveryInitiation(newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveRecoveryInitiation(address newOwner) 
        external 
        override 
        onlyGuardian 
        notFrozen 
        recoverable 
        notRecovering 
    {
        RecoveryRecord memory recoveryRecord = RecoveryRecord({
            isCompleted: false,
            isCancelled: false,
            cancelledBy: address(0),
            previousOwner: owner(),
            newOwner: newOwner,
            totalGuardians: recoveryConfig.customConfig.guardians.length,
            approvedGuardians: new address[](0),
            executableTime: block.timestamp + recoveryConfig.customConfig.recoveryTimeLock
        });
        recoveryRecords.push(recoveryRecord);
        _freezeAccount(msg.sender);
        emit SFAccount__RecoveryInitiated(newOwner);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function approveRecovery(address account) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveApproveRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveApproveRecovery() external override onlyGuardian notFrozen recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.approvedGuardians.push(msg.sender);
        emit SFAccount__RecoveryApproved(msg.sender);
        bool approvalIsSufficient = recoveryRecord.approvedGuardians.length >= recoveryConfig.customConfig.minGuardianApprovals;
        bool executableTimeReached = block.timestamp >= recoveryRecord.executableTime;
        if (approvalIsSufficient && executableTimeReached) {
            _completeRecovery();
        }
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function cancelRecovery(address account) 
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveCancelRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCancelRecovery() external override onlyGuardian notFrozen recoverable {
        RecoveryRecord storage recoveryRecord = _getPendingRecovery();
        recoveryRecord.isCancelled = true;
        recoveryRecord.cancelledBy = msg.sender;
        _unfreezeAccount(msg.sender);
        emit SFAccount__RecoveryCancelled(msg.sender);
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function completeRecovery(address account)
        external 
        override 
        onlyEntryPoint 
        notFrozen 
        recoverableAccount(account) 
    {
        ISFAccount(account).receiveCompleteRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function receiveCompleteRecovery() external override onlyGuardian notFrozen recoverable {
        _completeRecovery();
    }

    /// @inheritdoc ISocialRecoveryPlugin
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
        requiredApprovals = recoveryConfig.customConfig.minGuardianApprovals;
        executableTime = recoveryRecord.executableTime;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function getGuardians() external view override recoverable returns (address[] memory) {
        return recoveryConfig.customConfig.guardians;
    }

    /// @inheritdoc ISocialRecoveryPlugin
    function isGuardian(address account) external view recoverable override returns (bool) {
        return recoveryConfig.customConfig.guardians.contains(account);
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
        upkeepNeeded = _shouldTopUp();
        return (upkeepNeeded, performData);
    }

    /// @inheritdoc AutomationCompatibleInterface
    function performUpkeep(bytes calldata /* performData */) external override {
        if (_shouldTopUp()) {
            _topUpToMaintainCollateralRatio(sfEngine.getMinimumCollateralRatio());
        }
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
    ) internal view override returns (uint256 validationData) {
        address signer = ECDSA.recover(userOpHash, userOp.signature);
        return signer == owner() ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
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

    function _shouldTopUp() private returns (bool) {
        if (autoTopUpConfig.customConfig.autoTopUpEnabled) {
            (bool danger, uint256 collateralRatio, uint256 liquidationThreshold) = _checkCollateralSafety();
            if (danger) {
                emit SFAccount__Danger(collateralRatio, liquidationThreshold);
                return true;
            }
        }
        return false;
    }

    function _topUpCollateral(address collateralAddress, uint256 amount) private {
        uint256 collateralBalance = _getCollateralBalance(collateralAddress);
        if (collateralBalance < amount) {
            revert SFAccount__InsufficientCollateral(
                address(sfEngine), 
                collateralAddress, 
                collateralBalance, 
                amount
            );
        }
        emit SFAccount__TopUpCollateral(collateralAddress, amount);
        IERC20(collateralAddress).approve(address(sfEngine), amount);
        sfEngine.depositCollateralAndMintSFToken(collateralAddress, amount, 0);
    }

    function _topUpToMaintainCollateralRatio(uint256 targetCollateralRatio) private {
        uint256 sfDebt = _getSFDebt();
        uint256 currentCollateralInUsd = sfEngine.getTotalCollateralValueInUsd(address(this));
        uint256 requiredCollateralInUsd = sfDebt * targetCollateralRatio / PRECISION_FACTOR;
        if (currentCollateralInUsd >= requiredCollateralInUsd) {
            revert SFAccount__TopUpNotNeeded(currentCollateralInUsd, requiredCollateralInUsd, targetCollateralRatio);
        }
        uint256 collateralToTopUpInUsd = requiredCollateralInUsd - currentCollateralInUsd;
        address[] memory collaterals = depositedCollaterals.values();
        for (uint256 i = 0; i < collaterals.length && collateralToTopUpInUsd > 0; i++) {
            address priceFeed = supportedCollaterals[collaterals[i]];
            uint256 collateralBalance = _getCollateralBalance(collaterals[i]);
            if (priceFeed == address(0) || collateralBalance == 0) {
                continue;
            }
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
            uint256 currentCollateralRatio = requiredCollateralInUsd * PRECISION_FACTOR / sfDebt;
            emit SFAccount__InsufficientCollateralForTopUp(
                collateralToTopUpInUsd,
                currentCollateralRatio,
                targetCollateralRatio
            );
        }
        emit SFAccount__CollateralRatioMaintained(collateralToTopUpInUsd, targetCollateralRatio);
    }

    function _supportsSocialRecovery() private view returns (bool) {
        return recoveryConfig.customConfig.socialRecoveryEnabled;
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

    function _updateCustomRecoveryConfig(CustomRecoveryConfig memory customConfig) private {
        if (recoveryConfig.customConfig.socialRecoveryEnabled 
            && !customConfig.socialRecoveryEnabled) {
            // If disable social recovery, check whether account is in recovering process
            _requireNotRecovering();
        }
        if (customConfig.minGuardianApprovals == 0) {
            revert SFAccount__MinGuardianApprovalsIsNotSet();
        }
        if (customConfig.guardians.length == 0) {
            revert SFAccount__NoGuardianSet();
        }
        if (customConfig.minGuardianApprovals > customConfig.guardians.length) {
            revert SFAccount__ApprovalExceedsGuardianAmount(
                customConfig.minGuardianApprovals, 
                customConfig.guardians.length
            );
        }
        recoveryConfig.customConfig = customConfig;
        bytes memory configBytes = abi.encode(customConfig);
        emit SFAccount__UpdateCustomRecoveryConfig(customConfig.socialRecoveryEnabled, configBytes);
    }

    function _updateCustomAutoTopUpConfig(CustomAutoTopUpConfig memory customConfig) private {
        autoTopUpConfig.customConfig = customConfig;
        bytes memory configBytes = abi.encode(customConfig);
        emit SFAccount__UpdateCustomAutoTopUpConfig(customConfig.autoTopUpEnabled, configBytes);
    }

    function _requireSupportedCollateral(address collateral) private view {
        if (supportedCollaterals[collateral] == address(0)) {
            revert SFAccount__CollateralNotSupported(collateral);
        }
    }

    function _requireSFAccount(address account) private view {
        if (!account.supportsInterface(type(ISFAccount).interfaceId)) {
            revert SfAccount__NotSFAccount(account);
        }
    }

    function _requireNotRecovering() private view {
        if (_existsPendingRecovery()) {
            revert SFAccount__AccountIsInRecoveryProcess();
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
        uint256 minApprovals = recoveryConfig.customConfig.minGuardianApprovals;
        if (currentApprovals < minApprovals) {
            revert SFAccount__InsufficientApprovals(currentApprovals, minApprovals);
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

    function _unfreezeAccount(address unfreezedBy) private {
        _requireFrozen();
        FreezeRecord storage freezeRecord = freezeRecords[freezeRecords.length - 1];
        freezeRecord.isUnfreezed = true;
        freezeRecord.unfreezedBy = unfreezedBy;
        emit SFAccount__AccountUnfreezed(unfreezedBy);
    }

    function _getCollateralBalance(address collateralAddress) private view returns (uint256) {
        return IERC20(collateralAddress).balanceOf(address(this));
    }

    function _getSFTokenBalance() private view returns (uint256) {
        return IERC20(sfTokenAddress).balanceOf(address(this));
    }

    function _getSFDebt() private view returns (uint256) {
        return sfEngine.getSFDebt(address(this));
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