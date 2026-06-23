// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

/// @title  DeployEmpty
/// @notice Onboards the `Empty` contract to a new chain at its canonical address
///         `0xA4703438f8cc4fc2C2503a7e43935Da16BA74652` — the address `KpkOivFactory` bakes in as a
///         constant (`EMPTY_CONTRACT`) and uses as the Avatar Safe's sole signer. Because that
///         address is a hard-coded constant, every chain MUST host `Empty` at exactly this address
///         or `KpkOivFactory.deployOiv`/`deployStack` revert with `EmptyContractMissing`.
///
/// @dev    `Empty` was originally deployed via the CREATE2 helper factory
///         `0x7cbB62EaA69F79e6873cD1ecB2392971036cFAa4` (present on every supported chain). Replaying
///         the original creation calldata reproduces the same address regardless of caller —
///         verified caller-independent on a Polygon fork. Idempotent: skips if already deployed.
///
/// Usage (per chain):
///   source .env && forge script script/DeployEmpty.s.sol:DeployEmpty \
///     --rpc-url <chain> --private-key $PRIVATE_KEY --broadcast
contract DeployEmpty is Script {
    address internal constant EMPTY = 0xA4703438f8cc4fc2C2503a7e43935Da16BA74652;
    address internal constant HELPER_FACTORY = 0x7cbB62EaA69F79e6873cD1ecB2392971036cFAa4;

    /// @dev Exact creation calldata from the canonical Empty deployment (mainnet tx
    ///      0xc424...c8a2): selector 0x4847be6f + fixed salt + the Empty creation bytecode.
    bytes internal constant CREATE_CALLDATA =
        hex"4847be6f00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060307831313933333333333331393235323536383234373334353633343131000000000000000000000000000000000000000000000000000000000000000000586080604052348015600e575f5ffd5b50603e80601a5f395ff3fe60806040525f5ffdfea2646970667358221220dddfa414d3e674246761d7c4ce7ba241adbe729cb02d75a50b9cac1086c72cdf64736f6c634300081b00330000000000000000";

    function run() external {
        if (EMPTY.code.length > 0) {
            console.log("[SKIP] Empty already deployed at", EMPTY);
            return;
        }
        require(HELPER_FACTORY.code.length > 0, "Empty helper factory not on this chain");

        uint256 key = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(key);
        (bool ok,) = HELPER_FACTORY.call(CREATE_CALLDATA);
        require(ok, "Empty deploy via helper factory failed");
        vm.stopBroadcast();

        require(EMPTY.code.length > 0, "Empty not at canonical address after deploy");
        console.log("[OK] Empty deployed at", EMPTY);
    }
}
