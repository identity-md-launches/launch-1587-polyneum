// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @title DeployPolyneum
/// @notice Reviewable deployment entry point. The token takes no constructor arguments, so there is
///         no configuration to read: whoever sends the creation transaction receives the whole supply.
/// @dev On the IMD launch the factory deploys the token from its bytecode and this script is not used;
///      it exists so the deployment can be exercised locally and tested directly through `deploy()`.
///      `run()` does not read the environment: the broadcaster is chosen by the `forge script` flags.
contract DeployPolyneum is Script {
    /// @notice Deploys the token. Callable from tests without any broadcast or environment.
    /// @return token The deployed token; its whole supply belongs to `msg.sender` of this call's
    ///               creation, i.e. this script contract when called directly, or the broadcaster
    ///               when invoked through `run()`.
    function deploy() public returns (Polyneum token) {
        token = new Polyneum();
    }

    /// @notice Broadcast entry point for `forge script`. Not used by the IMD launch.
    function run() external returns (Polyneum token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
