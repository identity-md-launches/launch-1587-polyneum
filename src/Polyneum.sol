// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Polyneum (POLYNEUM)
/// @notice A fixed-supply ERC-20. The whole supply of 1,000,000,000 POLYNEUM (18 decimals) is minted
///         once, in the constructor, to the deployer (`msg.sender`). Nothing can mint afterwards.
/// @dev Deliberately minimal: no owner, no pause, no blacklist, no fee or burn on transfer, no
///      upgradeability, no external calls. Every transfer moves exactly the amount requested, so the
///      launch flows (factory -> distributor -> claimant, factory -> pool manager, trader <-> pool
///      manager) move exactly what they say. There are no privileged functions at all, so no hand can
///      move or freeze a holder's balance. The supply can only ever stay the same; it cannot grow.
///      The constructor takes no arguments and calls no other contract, so it deploys on an empty chain.
contract Polyneum is ERC20 {
    /// @notice The token name returned by `name()`.
    string public constant TOKEN_NAME = "Polyneum";

    /// @notice The token symbol returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "POLYNEUM";

    /// @notice Number of decimals, the ERC-20 default of 18.
    uint8 public constant DECIMALS = 18;

    /// @notice The entire, fixed supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** uint256(DECIMALS);

    /// @notice The address the whole supply was minted to: the deployer (`msg.sender` of the constructor).
    address public immutable initialHolder;

    /// @notice Emitted once, when the supply is minted to the deployer.
    event SupplyMinted(address indexed to, uint256 amount);

    /// @dev Mints the whole supply once to the deployer. In the launch, the deployer is the factory,
    ///      which distributes the supply (swarm share, pool seed, remainder) in its own transactions.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        initialHolder = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
        emit SupplyMinted(msg.sender, TOTAL_SUPPLY);
    }
}
