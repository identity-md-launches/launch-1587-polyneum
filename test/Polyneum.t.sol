// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Polyneum} from "../src/Polyneum.sol";
import {DeployPolyneum} from "../script/DeployPolyneum.s.sol";

/// @notice Behavioural tests for Polyneum: metadata, the single constructor mint, ordinary ERC-20
///         success and failure paths, the launch flows the factory performs, and the absence of any
///         mint or privileged function.
contract PolyneumTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint256 constant SWARM_BPS = 1000;
    uint256 constant POOL_BPS = 8800;

    /// @dev Stands in for the factory: the address that deploys and therefore holds the supply.
    address constant FACTORY = address(0xFAC7);
    address constant DISTRIBUTOR = address(0xD157);
    address constant CLAIMANT = address(0xC1A1);
    address constant POOL_MANAGER = address(0x900C);
    address constant REMAINDER_TO = 0x49c95a6EE32E9c0dC7A353c078e6158304BbCe9F;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant ATTACKER = address(0xBEEF);

    Polyneum token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event SupplyMinted(address indexed to, uint256 amount);

    function setUp() public {
        vm.prank(FACTORY);
        token = new Polyneum();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Polyneum");
        assertEq(token.symbol(), "POLYNEUM");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Polyneum");
        assertEq(token.TOKEN_SYMBOL(), "POLYNEUM");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyIsOneBillionWithEighteenDecimals() public view {
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000 * 1e18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.totalSupply(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_wholeSupplyMintedOnceToDeployer() public view {
        assertEq(token.balanceOf(FACTORY), SUPPLY, "deployer does not hold the whole supply");
        assertEq(token.initialHolder(), FACTORY);
        assertEq(token.balanceOf(address(this)), 0, "the test contract must not receive anything");
    }

    function test_constructorEmitsMintAndSupplyEvents() public {
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(0), ALICE, SUPPLY);
        vm.expectEmit(true, true, true, true);
        emit SupplyMinted(ALICE, SUPPLY);
        vm.prank(ALICE);
        Polyneum fresh = new Polyneum();
        assertEq(fresh.balanceOf(ALICE), SUPPLY);
        assertEq(fresh.initialHolder(), ALICE);
    }

    function test_deployerIsWhoeverSendsTheCreation() public {
        // Any deployer receives the supply; nothing is hard-wired to a particular address.
        vm.prank(BOB);
        Polyneum fresh = new Polyneum();
        assertEq(fresh.balanceOf(BOB), SUPPLY);
        assertEq(fresh.balanceOf(FACTORY), 0);
    }

    function test_deployScriptFunctionMintsToTheScript() public {
        DeployPolyneum deployer = new DeployPolyneum();
        Polyneum fresh = deployer.deploy();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(address(deployer)), SUPPLY);
        assertEq(fresh.name(), "Polyneum");
        assertEq(fresh.symbol(), "POLYNEUM");
    }

    // ---------------------------------------------------------------- transfer: success

    function test_transferMovesExactAmount() public {
        vm.prank(FACTORY);
        vm.expectEmit(true, true, true, true);
        emit Transfer(FACTORY, ALICE, 1234 ether);
        assertTrue(token.transfer(ALICE, 1234 ether));
        assertEq(token.balanceOf(ALICE), 1234 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1234 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfZeroSucceeds() public {
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(FACTORY, 5 ether));
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, SUPPLY));
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.balanceOf(ALICE), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != FACTORY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(to), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    // ---------------------------------------------------------------- transfer: failure

    function test_transferRevertsWhenBalanceInsufficient() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 10 ether, 11 ether)
        );
        token.transfer(BOB, 11 ether);
        assertEq(token.balanceOf(ALICE), 10 ether);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferRevertsFromEmptyAccount() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ATTACKER, 0, 1));
        token.transfer(BOB, 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(FACTORY);
        vm.expectEmit(true, true, true, true);
        emit Approval(FACTORY, ALICE, 7 ether);
        assertTrue(token.approve(ALICE, 7 ether));
        assertEq(token.allowance(FACTORY, ALICE), 7 ether);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromSpendsAllowanceExactly() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 100 ether);
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit Transfer(FACTORY, BOB, 60 ether);
        assertTrue(token.transferFrom(FACTORY, BOB, 60 ether));
        assertEq(token.balanceOf(BOB), 60 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 60 ether);
        assertEq(token.allowance(FACTORY, ALICE), 40 ether);
    }

    function test_transferFromWithMaxAllowanceDoesNotDecrement() public {
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, 1 ether));
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ATTACKER, 0, 1 ether));
        token.transferFrom(FACTORY, ATTACKER, 1 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(ATTACKER), 0);
    }

    function test_transferFromRevertsWhenAllowanceTooSmall() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 5 ether, 6 ether)
        );
        token.transferFrom(FACTORY, BOB, 6 ether);
        assertEq(token.allowance(FACTORY, ALICE), 5 ether);
    }

    function test_transferFromRevertsWhenOwnerBalanceInsufficient() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 1 ether);
        vm.prank(ALICE);
        token.approve(BOB, 2 ether);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 1 ether, 2 ether));
        token.transferFrom(ALICE, BOB, 2 ether);
    }

    // ---------------------------------------------------------------- launch flows

    function test_launchFlowsMoveExactlyWhatTheySay() public {
        uint256 swarm = (SUPPLY * SWARM_BPS) / 10_000;
        uint256 pool = (SUPPLY * POOL_BPS) / 10_000;
        uint256 remainder = SUPPLY - swarm - pool;

        vm.startPrank(FACTORY);
        assertTrue(token.transfer(DISTRIBUTOR, swarm));
        assertTrue(token.transfer(POOL_MANAGER, pool));
        assertTrue(token.transfer(REMAINDER_TO, remainder));
        vm.stopPrank();

        assertEq(token.balanceOf(DISTRIBUTOR), swarm, "swarm share arrived short");
        assertEq(token.balanceOf(POOL_MANAGER), pool, "pool seed arrived short");
        assertEq(token.balanceOf(REMAINDER_TO), remainder, "remainder arrived short");
        assertEq(token.balanceOf(FACTORY), 0, "factory kept something back");

        vm.prank(DISTRIBUTOR);
        assertTrue(token.transfer(CLAIMANT, swarm));
        assertEq(token.balanceOf(CLAIMANT), swarm, "claim arrived short");
        assertEq(token.balanceOf(DISTRIBUTOR), 0);

        // A trader buys from and sells back into the pool manager with no loss.
        vm.prank(POOL_MANAGER);
        token.transfer(ALICE, 1000 ether);
        assertEq(token.balanceOf(ALICE), 1000 ether);
        vm.prank(ALICE);
        token.transfer(POOL_MANAGER, 1000 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(POOL_MANAGER), pool);

        assertEq(token.totalSupply(), SUPPLY, "launch flows changed the supply");
    }

    // ---------------------------------------------------------------- no mint, no privileged hand

    function test_noMintOrAdminSelectorExists() public {
        string[14] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "blacklist(address)",
            "freeze(address)",
            "upgradeTo(address)",
            "setMinter(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            bytes memory data = abi.encodeWithSignature(signatures[i], ATTACKER, type(uint128).max);
            vm.prank(ATTACKER);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(FACTORY);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ATTACKER), 0);
    }

    function test_deployerCannotMoveAHoldersBalance() public {
        vm.prank(FACTORY);
        token.transfer(ALICE, 50 ether);
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        token.transferFrom(ALICE, FACTORY, 1);
        assertEq(token.balanceOf(ALICE), 50 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 25 ether));
        assertEq(token.balanceOf(BOB), 25 ether);
    }

    function test_plainEtherIsRejected() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token must not accept ether");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i = 0; i < runtime.length; i++) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    function test_supportsTheIERC20Surface() public view {
        IERC20 erc20 = IERC20(address(token));
        assertEq(erc20.totalSupply(), SUPPLY);
        assertEq(erc20.balanceOf(FACTORY), SUPPLY);
        assertEq(erc20.allowance(FACTORY, ALICE), 0);
    }
}
