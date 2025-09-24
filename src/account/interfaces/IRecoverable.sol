// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IRecoverable {

    function supportsSocialRecovery() external view returns (bool);

    function enableSocialRecovery() external;

    function disableSocialRecovery() external;

    function initiateRecovery(address account, address newOwner) external;

    function receiveRecoveryInitiation(address newOwner) external;

    function approveRecovery(address account) external;

    function receiveRecoveryApproval(address guardian) external;

    function cancelRecovery(address account) external;

    function receiveRecoveryCancellation(address guardian) external;

    function getRecoveryProgress() external view returns (
        bool isInRecoveryProgress, 
        uint256 currentApprovals, 
        uint256 requiredApprovals, 
        uint256 executableTime
    );

    function getGuardians() external view returns (address[] memory);

    function addGuardian(address guardian) external;

    function removeGuardian(address guardian) external;

    function isGuardian(address account) external view returns (bool);
}