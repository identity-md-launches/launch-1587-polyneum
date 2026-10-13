// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Stateless property tests for Polyneum at the edges of its input domain, with the known edge
///         cases (zero, one wei, the whole supply, the maximum) pinned as plain unit tests beside them.
///         Each failure path asserts the exact ERC-6093 error and that the revert left no trace.
/// forge-config: default.fuzz.runs = 1000
contract PolyneumFuzzTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    address constant FACTORY = address(0xFAC7);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);

    Polyneum token;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        vm.prank(FACTORY);
        token = new Polyneum();
    }

    // ---------------------------------------------------------------- constructor

    function testFuzz_anyDeployerReceivesTheWholeSupply(address deployer) public {
        deployer = address(uint160(bound(uint160(deployer), 1, type(uint160).max)));
        vm.prank(deployer);
        Polyneum fresh = new Polyneum();
        assertEq(fresh.totalSupply(), SUPPLY);
        assertEq(fresh.balanceOf(deployer), SUPPLY);
        assertEq(fresh.initialHolder(), deployer);
    }

    function test_twoDeploymentsAreIndependent() public {
        vm.prank(ALICE);
        Polyneum second = new Polyneum();
        assertEq(second.balanceOf(ALICE), SUPPLY);
        assertEq(second.balanceOf(FACTORY), 0);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        vm.prank(ALICE);
        second.transfer(BOB, 1);
        assertEq(token.balanceOf(BOB), 0, "a transfer on one token touched another");
    }

    function test_supplyFitsTheWidestLaunchArithmetic() public pure {
        // The factory computes bps shares of the supply as supply * bps / 10_000; no overflow room needed.
        assertLt(SUPPLY, type(uint256).max / 10_000);
        assertEq((SUPPLY * 1000) / 10_000, 100_000_000 ether, "swarm share is not ten percent");
        assertEq(SUPPLY % 10_000, 0, "supply is not divisible into whole bps");
    }

    // ---------------------------------------------------------------- transfer properties

    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, amount);
        vm.prank(ALICE);
        token.transfer(FACTORY, amount);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.balanceOf(ALICE), 0);
    }

    function testFuzz_transferToSelfIsANoOp(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        vm.expectEmit(true, true, true, true);
        emit Transfer(FACTORY, FACTORY, amount);
        assertTrue(token.transfer(FACTORY, amount));
        assertEq(token.balanceOf(FACTORY), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransfersSumExactly(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 0, SUPPLY);
        b = bound(b, 0, SUPPLY - a);
        c = bound(c, 0, SUPPLY - a - b);
        vm.startPrank(FACTORY);
        token.transfer(ALICE, a);
        token.transfer(ALICE, b);
        token.transfer(BOB, c);
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), a + b);
        assertEq(token.balanceOf(BOB), c);
        assertEq(token.balanceOf(FACTORY), SUPPLY - a - b - c);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(ALICE) + token.balanceOf(BOB), SUPPLY);
    }

    function testFuzz_transferAboveBalanceRevertsAndChangesNothing(uint256 held, uint256 excess) public {
        held = bound(held, 0, SUPPLY);
        excess = bound(excess, 1, type(uint256).max - held);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, held + excess)
        );
        token.transfer(BOB, held + excess);
        assertEq(token.balanceOf(ALICE), held);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transferOfSupplyPlusOneReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, SUPPLY + 1)
        );
        token.transfer(ALICE, SUPPLY + 1);
    }

    function test_transferOfMaxUintReverts() public {
        vm.prank(FACTORY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, FACTORY, SUPPLY, type(uint256).max)
        );
        token.transfer(ALICE, type(uint256).max);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_transferOfOneWeiMovesOneWei() public {
        vm.prank(FACTORY);
        assertTrue(token.transfer(ALICE, 1));
        assertEq(token.balanceOf(ALICE), 1);
        assertEq(token.balanceOf(FACTORY), SUPPLY - 1);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 1));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 1));
        token.transfer(BOB, 1);
    }

    function testFuzz_zeroAddressReceiverAlwaysRejected(uint256 amount) public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_zeroAddressReceiverCheckedBeforeBalance() public {
        // An empty account sending to the zero address: the receiver check wins over the balance check.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_zeroAddressSenderRejectedEvenForZeroAmount() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(ALICE, 0);
    }

    function test_zeroAddressCannotApprove() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(ALICE, 1);
    }

    function testFuzz_transferToTheTokenItselfIsAcceptedAndStuck(uint256 amount) public {
        // Nothing stops a holder from sending tokens to the token contract, and nothing can move them
        // out again: there is no rescue function. The README documents this as holder responsibility.
        amount = bound(amount, 1, SUPPLY);
        vm.prank(FACTORY);
        assertTrue(token.transfer(address(token), amount));
        assertEq(token.balanceOf(address(token)), amount);
        assertEq(token.balanceOf(FACTORY) + token.balanceOf(address(token)), SUPPLY);
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, FACTORY, 0, 1));
        token.transferFrom(address(token), FACTORY, 1);
    }

    function testFuzz_transferEmitsExactEvent(address to, uint256 amount) public {
        to = address(uint160(bound(uint160(to), 1, type(uint160).max)));
        amount = bound(amount, 0, SUPPLY);
        vm.prank(FACTORY);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(FACTORY, to, amount);
        token.transfer(to, amount);
    }

    // ---------------------------------------------------------------- approve properties

    function testFuzz_approveOverwritesNotAccumulates(uint256 first, uint256 second) public {
        vm.startPrank(FACTORY);
        token.approve(ALICE, first);
        assertEq(token.allowance(FACTORY, ALICE), first);
        token.approve(ALICE, second);
        vm.stopPrank();
        assertEq(token.allowance(FACTORY, ALICE), second, "approve must replace, not add");
        assertEq(token.allowance(ALICE, FACTORY), 0, "approve is directional");
        assertEq(token.balanceOf(FACTORY), SUPPLY, "approve moved tokens");
    }

    function testFuzz_approveDoesNotRequireBalance(address owner, uint256 amount) public {
        owner = address(uint160(bound(uint160(owner), 1, type(uint160).max)));
        vm.prank(owner);
        assertTrue(token.approve(BOB, amount));
        assertEq(token.allowance(owner, BOB), amount);
    }

    function testFuzz_approveZeroSpenderAlwaysRejected(uint256 amount) public {
        vm.prank(FACTORY);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), amount);
        assertEq(token.allowance(FACTORY, address(0)), 0);
    }

    function test_approveIsIdempotent() public {
        vm.startPrank(FACTORY);
        token.approve(ALICE, 9 ether);
        token.approve(ALICE, 9 ether);
        vm.stopPrank();
        assertEq(token.allowance(FACTORY, ALICE), 9 ether);
    }

    function testFuzz_revokeThenSpendReverts(uint256 granted, uint256 spend) public {
        granted = bound(granted, 1, SUPPLY);
        spend = bound(spend, 1, granted);
        vm.startPrank(FACTORY);
        token.approve(ALICE, granted);
        token.approve(ALICE, 0);
        vm.stopPrank();
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, spend));
        token.transferFrom(FACTORY, ALICE, spend);
        assertEq(token.balanceOf(ALICE), 0);
    }

    // ---------------------------------------------------------------- transferFrom properties

    function testFuzz_transferFromDecrementsFiniteAllowanceExactly(uint256 allowance, uint256 spend) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        spend = bound(spend, 0, allowance < SUPPLY ? allowance : SUPPLY);
        vm.prank(FACTORY);
        token.approve(ALICE, allowance);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, BOB, spend));
        assertEq(token.allowance(FACTORY, ALICE), allowance - spend);
        assertEq(token.balanceOf(BOB), spend);
        assertEq(token.balanceOf(FACTORY), SUPPLY - spend);
    }

    function testFuzz_infiniteAllowanceNeverDecrements(uint256 spend, uint8 times) public {
        times = uint8(bound(times, 1, 8));
        spend = bound(spend, 0, SUPPLY / times);
        vm.prank(FACTORY);
        token.approve(ALICE, type(uint256).max);
        vm.startPrank(ALICE);
        for (uint256 i = 0; i < times; i++) {
            assertTrue(token.transferFrom(FACTORY, BOB, spend));
        }
        vm.stopPrank();
        assertEq(token.allowance(FACTORY, ALICE), type(uint256).max);
        assertEq(token.balanceOf(BOB), spend * times);
    }

    function testFuzz_transferFromAboveAllowanceRevertsAndChangesNothing(uint256 allowance, uint256 excess) public {
        allowance = bound(allowance, 0, type(uint256).max - 1);
        excess = bound(excess, 1, type(uint256).max - allowance);
        vm.prank(FACTORY);
        token.approve(ALICE, allowance);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, allowance, allowance + excess
            )
        );
        token.transferFrom(FACTORY, BOB, allowance + excess);
        assertEq(token.allowance(FACTORY, ALICE), allowance, "a failed spend changed the allowance");
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function testFuzz_allowanceCheckedBeforeBalance(uint256 held, uint256 allowance) public {
        // The owner holds less than the allowance: a spend between the two fails on balance, with the
        // allowance left intact.
        held = bound(held, 0, SUPPLY - 1);
        allowance = bound(allowance, held + 1, SUPPLY);
        vm.prank(FACTORY);
        token.transfer(ALICE, held);
        vm.prank(ALICE);
        token.approve(BOB, allowance);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, held, allowance));
        token.transferFrom(ALICE, BOB, allowance);
        assertEq(token.allowance(ALICE, BOB), allowance, "allowance consumed by a failed transfer");
        assertEq(token.balanceOf(ALICE), held);
    }

    function test_transferFromOfZeroNeedsNoAllowance() public {
        // A zero-amount transferFrom passes the allowance check (0 <= 0) and emits a zero Transfer.
        vm.prank(ALICE);
        vm.expectEmit(true, true, true, true);
        emit Transfer(FACTORY, BOB, 0);
        assertTrue(token.transferFrom(FACTORY, BOB, 0));
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.allowance(FACTORY, ALICE), 0);
    }

    function test_transferFromZeroAddressOwnerReverts() public {
        // Zero amount passes the allowance comparison (0 <= 0), but OZ then writes the spent allowance
        // back through _approve, which rejects a zero owner before _transfer ever sees the zero sender.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
        assertEq(token.balanceOf(BOB), 0);
    }

    function test_transferFromZeroAddressOwnerWithAmountFailsOnAllowance() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(address(0), BOB, 1);
    }

    function test_transferFromToZeroAddressRevertsEvenWithAllowance() public {
        vm.prank(FACTORY);
        token.approve(ALICE, 5 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(FACTORY, address(0), 5 ether);
        assertEq(token.allowance(FACTORY, ALICE), 5 ether);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function test_transferFromSpendingTheWholeSupply() public {
        vm.prank(FACTORY);
        token.approve(ALICE, SUPPLY);
        vm.prank(ALICE);
        assertTrue(token.transferFrom(FACTORY, ALICE, SUPPLY));
        assertEq(token.balanceOf(ALICE), SUPPLY);
        assertEq(token.balanceOf(FACTORY), 0);
        assertEq(token.allowance(FACTORY, ALICE), 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, ALICE, 0, 1));
        token.transferFrom(FACTORY, ALICE, 1);
    }

    function test_selfApprovedTransferFromSpendsAllowance() public {
        // An owner spending its own allowance is an ordinary spender: the allowance is consumed.
        vm.startPrank(FACTORY);
        token.approve(FACTORY, 3 ether);
        assertTrue(token.transferFrom(FACTORY, ALICE, 2 ether));
        vm.stopPrank();
        assertEq(token.allowance(FACTORY, FACTORY), 1 ether);
        assertEq(token.balanceOf(ALICE), 2 ether);
    }

    function testFuzz_transferFromDoesNotEmitApprovalOnSpend(uint256 allowance, uint256 spend) public {
        // OZ v5 spends silently: no Approval event on transferFrom, only the Transfer.
        allowance = bound(allowance, 1, SUPPLY);
        spend = bound(spend, 1, allowance);
        vm.prank(FACTORY);
        token.approve(ALICE, allowance);
        vm.recordLogs();
        vm.prank(ALICE);
        token.transferFrom(FACTORY, BOB, spend);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "transferFrom must emit exactly one event");
        assertEq(logs[0].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    // ---------------------------------------------------------------- unknown calls

    function testFuzz_unknownSelectorsAlwaysRevert(bytes4 selector, bytes calldata args) public {
        vm.assume(
            selector != token.transfer.selector && selector != token.approve.selector
                && selector != token.transferFrom.selector && selector != token.balanceOf.selector
                && selector != token.allowance.selector && selector != token.totalSupply.selector
                && selector != token.name.selector && selector != token.symbol.selector
                && selector != token.decimals.selector && selector != token.TOKEN_NAME.selector
                && selector != token.TOKEN_SYMBOL.selector && selector != token.DECIMALS.selector
                && selector != token.TOTAL_SUPPLY.selector && selector != token.initialHolder.selector
        );
        vm.prank(FACTORY);
        (bool ok,) = address(token).call(abi.encodePacked(selector, args));
        assertFalse(ok, "the token answered a selector it does not define");
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(FACTORY), SUPPLY);
    }

    function testFuzz_etherWithAnyCalldataIsRejected(bytes calldata data, uint96 value) public {
        value = uint96(bound(value, 1, type(uint96).max));
        vm.deal(ALICE, value);
        vm.prank(ALICE);
        (bool ok,) = address(token).call{value: value}(data);
        assertFalse(ok, "the token accepted ether");
        assertEq(address(token).balance, 0);
    }
}
