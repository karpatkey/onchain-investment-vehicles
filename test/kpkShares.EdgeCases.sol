// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

contract DeploymentConfigTest is Test {
    function test_validateDeploymentEnv() public {
        string[] memory cmd = new string[](2);
        cmd[0] = "bash";
        cmd[1] = "scripts/validate-env.sh";
        bytes memory output = vm.ffi(cmd);
        assertTrue(output.length > 0, "Environment validation should produce output");
    }

    function test_vaultConfigReadable() public {
        string memory config = vm.readFile("script/vaults.json");
        assertTrue(bytes(config).length > 0, "Vault config should be readable");
    }
}
