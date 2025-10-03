// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, stdJson} from "forge-std/Script.sol";

contract DevOps is Script {

    using stdJson for string;

    error DevOps__NameAndDeploymentsLengthNotMatch();
    error DevOps__NotDeployed(string name);

    string private constant LATEST_DEPLOYMENT_FILE_PATH = "script/config/LatestDeployment.json";

    function getLatestDeployment(string memory name) external view returns (address) {
        string memory json = vm.readFile(LATEST_DEPLOYMENT_FILE_PATH);
        string memory key = string.concat(".", name, vm.toString(block.chainid));
        if (!json.keyExists(key)) {
            revert DevOps__NotDeployed(name);
        }
        return vm.parseJsonAddress(json, key);
    }

    function saveDeployment(string[] memory names, address[] memory deployments) external {
        if (names.length != deployments.length) {
            revert DevOps__NameAndDeploymentsLengthNotMatch();
        }
        string memory developments = "developments";
        string memory development = "development";
        string memory developmentJson;
        string memory developmentsJson;
        for (uint256 i = 0; i < names.length; i++) {
            developmentJson = development.serialize(names[i], deployments[i]);
        }
        developmentsJson = developments.serialize(vm.toString(block.chainid), developmentJson);
        developmentsJson.write(LATEST_DEPLOYMENT_FILE_PATH);
    }
}