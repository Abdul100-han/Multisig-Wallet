// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {MultiSigWallet} from "../src/MultiSigWallet.sol";

/// @notice Deploys MultiSigWallet with a 2-of-3 owner set.
/// @dev Reads `PRIVATE_KEY` for the deployer. Owner addresses come from `OWNER_1`, `OWNER_2`, and `OWNER_3`.
///      Missing owner variables fall back to Foundry's first three default Anvil accounts.
contract DeployMultiSigWallet is Script {
    uint256 internal constant THRESHOLD = 2;

    /// @dev Anvil account #0. Used only when `OWNER_1` is unset.
    address internal constant DEFAULT_OWNER_1 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    /// @dev Anvil account #1. Used only when `OWNER_2` is unset.
    address internal constant DEFAULT_OWNER_2 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    /// @dev Anvil account #2. Used only when `OWNER_3` is unset.
    address internal constant DEFAULT_OWNER_3 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        address[] memory owners = new address[](3);
        owners[0] = vm.envOr("OWNER_1", DEFAULT_OWNER_1);
        owners[1] = vm.envOr("OWNER_2", DEFAULT_OWNER_2);
        owners[2] = vm.envOr("OWNER_3", DEFAULT_OWNER_3);

        console2.log("Owner 1:", owners[0]);
        console2.log("Owner 2:", owners[1]);
        console2.log("Owner 3:", owners[2]);
        console2.log("Threshold:", THRESHOLD);

        vm.startBroadcast(deployerPrivateKey);
        MultiSigWallet wallet = new MultiSigWallet(owners, THRESHOLD);
        vm.stopBroadcast();

        console2.log("MultiSigWallet deployed to:", address(wallet));
    }
}
