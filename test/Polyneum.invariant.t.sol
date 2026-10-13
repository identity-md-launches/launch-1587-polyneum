// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Polyneum} from "../src/Polyneum.sol";

/// @notice Drives the token with random sequences of transfer / approve / transferFrom from a set of
///         actors, with both clamped (always-succeeding) and unclamped (may-revert) entry points, and
///         keeps ghost accounting of what every address should hold and what every allowance should be.
/// @dev Every revert the unclamped layer provokes is caught and checked: it must be the exact ERC-6093
///      error the inputs call for, and it must leave every balance and allowance untouched. A revert the
///      handler did not expect is surfaced as a failed assertion, so fail-on-revert can stay on.
contract PolyneumHandler is Test {
    Polyneum public immutable token;
    uint256 public immutable supply;

    address[] public actors;
    mapping(address => bool) public isActor;

    /// @dev Every address that has ever been named as a sender or receiver, so the invariant can sum
    ///      balances over the whole set of addresses that could possibly hold anything.
    address[] public touched;
    mapping(address => bool) public isTouched;

    /// @dev Ghost model of balances: net of every successful transfer the handler drove, starting
    ///      from the constructor mint.
    mapping(address => uint256) public ghostBalance;
    /// @dev Ghost model of allowances: the last approve, less every finite spend.
    mapping(address => mapping(address => uint256)) public ghostAllowance;
    /// @dev Cumulative amount ever received by an address (excluding the mint), to check that nobody
    ///      ends up holding more than what flowed into them plus what they were minted.
    mapping(address => uint256) public ghostReceived;
    mapping(address => uint256) public ghostSent;

    uint256 public ghostTotalMoved;
    uint256 public callsSucceeded;
    uint256 public callsReverted;
    uint256 public callsTransfer;
    uint256 public callsApprove;
    uint256 public callsTransferFrom;

    address internal currentActor;

    constructor(Polyneum token_, address[] memory actors_) {
        token = token_;
        supply = token_.totalSupply();
        for (uint256 i = 0; i < actors_.length; i++) {
            _addActor(actors_[i]);
        }
        // The token contract itself is a legal (if unfortunate) receiver: nothing stops tokens being
        // sent there, and once there nothing can move them. It is tracked so conservation still holds.
        _touch(address(token_));
        address holder = token_.initialHolder();
        _touch(holder);
        // Start the ghost model from the chain's current state: whatever the test seeded before
        // handing over counts as having flowed out of the initial holder into the seeded actors.
        uint256 seeded;
        for (uint256 i = 0; i < touched.length; i++) {
            address a = touched[i];
            uint256 bal = token_.balanceOf(a);
            ghostBalance[a] = bal;
            if (a != holder) {
                ghostReceived[a] = bal;
                seeded += bal;
            }
        }
        ghostSent[holder] = seeded;
        require(ghostBalance[holder] + seeded == supply, "handler must see every seeded address");
    }

    // ------------------------------------------------------------------ actor plumbing

    function _addActor(address a) internal {
        if (isActor[a]) return;
        isActor[a] = true;
        actors.push(a);
        _touch(a);
    }

    function _touch(address a) internal {
        if (a == address(0) || isTouched[a]) return;
        isTouched[a] = true;
        touched.push(a);
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function touchedCount() external view returns (uint256) {
        return touched.length;
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    modifier useActor(uint256 seed) {
        currentActor = _pickActor(seed);
        vm.startPrank(currentActor);
        _;
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ snapshot helpers

    struct Snap {
        uint256 fromBal;
        uint256 toBal;
        uint256 spenderBal;
        uint256 allowance;
        uint256 total;
    }

    function _snap(address from, address to, address spender) internal view returns (Snap memory s) {
        s.fromBal = token.balanceOf(from);
        s.toBal = token.balanceOf(to);
        s.spenderBal = token.balanceOf(spender);
        s.allowance = token.allowance(from, spender);
        s.total = token.totalSupply();
    }

    function _assertUnchanged(Snap memory s, address from, address to, address spender) internal view {
        assertEq(token.balanceOf(from), s.fromBal, "revert changed sender balance");
        assertEq(token.balanceOf(to), s.toBal, "revert changed receiver balance");
        assertEq(token.balanceOf(spender), s.spenderBal, "revert changed spender balance");
        assertEq(token.allowance(from, spender), s.allowance, "revert changed allowance");
        assertEq(token.totalSupply(), s.total, "revert changed total supply");
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        ghostSent[from] += amount;
        ghostReceived[to] += amount;
        ghostTotalMoved += amount;
        _touch(to);
        callsSucceeded++;
    }

    // ------------------------------------------------------------------ unclamped: raw calls, any input

    /// @notice transfer with an unrestricted receiver and amount from a random actor.
    function transfer_unclamped(uint256 actorSeed, address to, uint256 amount) public useActor(actorSeed) {
        callsTransfer++;
        address from = currentActor;
        Snap memory s = _snap(from, to, from);
        uint256 balance = token.balanceOf(from);

        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertTrue(to != address(0), "transfer to zero address succeeded");
            assertLe(amount, balance, "transfer above balance succeeded");
            _recordTransfer(from, to, amount);
        } catch (bytes memory reason) {
            callsReverted++;
            if (to == address(0)) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
                    "wrong error"
                );
            } else {
                assertGt(amount, balance, "transfer within balance reverted");
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
                    "wrong error"
                );
            }
            _assertUnchanged(s, from, to, from);
        }
    }

    /// @notice approve with an unrestricted spender and amount from a random actor.
    function approve_unclamped(uint256 actorSeed, address spender, uint256 amount) public useActor(actorSeed) {
        callsApprove++;
        address owner = currentActor;
        Snap memory s = _snap(owner, spender, spender);

        try token.approve(spender, amount) returns (bool ok) {
            assertTrue(ok, "approve returned false");
            assertTrue(spender != address(0), "approve of zero spender succeeded");
            assertEq(token.allowance(owner, spender), amount, "approve did not set the exact amount");
            assertEq(token.balanceOf(owner), s.fromBal, "approve changed a balance");
            ghostAllowance[owner][spender] = amount;
            _touch(spender);
            callsSucceeded++;
        } catch (bytes memory reason) {
            callsReverted++;
            assertEq(spender, address(0), "approve of a nonzero spender reverted");
            assertEq(
                reason, abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)), "wrong error"
            );
            _assertUnchanged(s, owner, spender, spender);
        }
    }

    /// @notice transferFrom with an unrestricted owner (chosen among touched addresses, or the zero
    ///         address), receiver and amount, from a random actor as spender.
    function transferFrom_unclamped(uint256 actorSeed, uint256 fromSeed, address to, uint256 amount)
        public
        useActor(actorSeed)
    {
        callsTransferFrom++;
        address spender = currentActor;
        // One slot past the end stands for the zero address as owner, an input OZ must reject.
        uint256 idx = fromSeed % (touched.length + 1);
        address from = idx == touched.length ? address(0) : touched[idx];
        _transferFromRaw(spender, from, to, amount);
    }

    function _transferFromRaw(address spender, address from, address to, uint256 amount) internal {
        Snap memory s = _snap(from, to, spender);
        uint256 allowance = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);

        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(from != address(0), "transferFrom from the zero address succeeded");
            assertTrue(to != address(0), "transferFrom to the zero address succeeded");
            assertLe(amount, allowance, "transferFrom above allowance succeeded");
            assertLe(amount, balance, "transferFrom above balance succeeded");
            if (allowance == type(uint256).max) {
                assertEq(token.allowance(from, spender), type(uint256).max, "infinite allowance was decremented");
            } else {
                assertEq(token.allowance(from, spender), allowance - amount, "allowance not decremented exactly");
                ghostAllowance[from][spender] = allowance - amount;
            }
            _recordTransfer(from, to, amount);
        } catch (bytes memory reason) {
            callsReverted++;
            if (amount > allowance) {
                // Allowance is checked first, before the sender, receiver and balance.
                assertEq(
                    reason,
                    abi.encodeWithSelector(
                        IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowance, amount
                    ),
                    "wrong error"
                );
            } else if (from == address(0)) {
                // The allowance is spent before the sender is checked, and writing the spent allowance
                // back for a zero owner is what OZ rejects: InvalidApprover, not InvalidSender.
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)),
                    "wrong error"
                );
            } else if (to == address(0)) {
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)),
                    "wrong error"
                );
            } else {
                assertGt(amount, balance, "transferFrom within allowance and balance reverted");
                assertEq(
                    reason,
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balance, amount),
                    "wrong error"
                );
            }
            _assertUnchanged(s, from, to, spender);
        }
    }

    // ------------------------------------------------------------------ clamped: high-signal calls

    /// @notice Transfer a bounded amount between two actors; never reverts.
    function transfer(uint256 actorSeed, uint256 toSeed, uint256 amount) public {
        address from = _pickActor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        transfer_unclamped(actorSeed, _pickActor(toSeed), amount);
    }

    /// @notice Transfer an actor's entire balance (the full-amount stress variant).
    function transferAll(uint256 actorSeed, uint256 toSeed) public {
        address from = _pickActor(actorSeed);
        transfer_unclamped(actorSeed, _pickActor(toSeed), token.balanceOf(from));
    }

    /// @notice Transfer one wei (the near-zero stress variant) or zero.
    function transferDust(uint256 actorSeed, uint256 toSeed, bool oneWei) public {
        address from = _pickActor(actorSeed);
        uint256 amount = oneWei && token.balanceOf(from) > 0 ? 1 : 0;
        transfer_unclamped(actorSeed, _pickActor(toSeed), amount);
    }

    /// @notice Transfer to self: must be a no-op on the balance.
    function transferSelf(uint256 actorSeed, uint256 amount) public {
        address from = _pickActor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        uint256 before = token.balanceOf(from);
        transfer_unclamped(actorSeed, from, amount);
        assertEq(token.balanceOf(from), before, "self transfer changed balance");
    }

    /// @notice Transfer strictly more than the balance: must revert with ERC20InsufficientBalance.
    function transferTooMuch(uint256 actorSeed, uint256 toSeed, uint256 excess) public {
        address from = _pickActor(actorSeed);
        uint256 balance = token.balanceOf(from);
        excess = bound(excess, 1, type(uint256).max - balance);
        transfer_unclamped(actorSeed, _pickActor(toSeed), balance + excess);
    }

    /// @notice Send tokens to the token contract itself (the donation pattern): they are stuck there
    ///         but conservation must still hold.
    function donateToToken(uint256 actorSeed, uint256 amount) public {
        address from = _pickActor(actorSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        transfer_unclamped(actorSeed, address(token), amount);
    }

    /// @notice Approve a bounded amount to another actor; never reverts.
    function approve(uint256 actorSeed, uint256 spenderSeed, uint256 amount) public {
        approve_unclamped(actorSeed, _pickActor(spenderSeed), amount);
    }

    /// @notice Approve the infinite allowance.
    function approveMax(uint256 actorSeed, uint256 spenderSeed) public {
        approve_unclamped(actorSeed, _pickActor(spenderSeed), type(uint256).max);
    }

    /// @notice Revoke an allowance.
    function approveZero(uint256 actorSeed, uint256 spenderSeed) public {
        approve_unclamped(actorSeed, _pickActor(spenderSeed), 0);
    }

    /// @notice transferFrom within both allowance and balance; never reverts.
    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount)
        public
        useActor(spenderSeed)
    {
        callsTransferFrom++;
        address spender = currentActor;
        address from = _pickActor(fromSeed);
        uint256 cap = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        if (balance < cap) cap = balance;
        amount = bound(amount, 0, cap);
        _transferFromRaw(spender, from, _pickActor(toSeed), amount);
    }

    /// @notice transferFrom of the whole allowance (or whole balance, whichever is smaller).
    function transferFromAll(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed) public useActor(spenderSeed) {
        callsTransferFrom++;
        address spender = currentActor;
        address from = _pickActor(fromSeed);
        uint256 cap = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        if (balance < cap) cap = balance;
        _transferFromRaw(spender, from, _pickActor(toSeed), cap);
    }

    /// @notice transferFrom one more than the allowance: must revert with ERC20InsufficientAllowance.
    function transferFromOverAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed)
        public
        useActor(spenderSeed)
    {
        callsTransferFrom++;
        address spender = currentActor;
        address from = _pickActor(fromSeed);
        uint256 allowance = token.allowance(from, spender);
        if (allowance == type(uint256).max) return;
        _transferFromRaw(spender, from, _pickActor(toSeed), allowance + 1);
    }

    /// @notice An attempt by anyone to reach a mint, burn or admin function; must never succeed.
    function callForeignSelector(uint256 actorSeed, uint8 which, address target, uint256 amount)
        public
        useActor(actorSeed)
    {
        string[8] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "blacklist(address)",
            "transferOwnership(address)",
            "upgradeTo(address)"
        ];
        bytes memory data = abi.encodeWithSignature(signatures[which % signatures.length], target, amount);
        (bool ok,) = address(token).call(data);
        assertFalse(ok, "a foreign selector was accepted");
        callsReverted++;
    }
}

/// @notice Invariants Polyneum must keep over any sequence of calls the handler can drive.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PolyneumInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    address constant FACTORY = address(0xFAC7);

    Polyneum token;
    PolyneumHandler handler;
    address[] actors;

    function setUp() public {
        vm.prank(FACTORY);
        token = new Polyneum();

        actors.push(FACTORY);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(address(0xDA7E));

        // Seed a few actors so that approve / transferFrom paths are reachable from the start. The
        // handler reads these balances into its ghost model when it is constructed.
        vm.startPrank(FACTORY);
        token.transfer(actors[1], SUPPLY / 10);
        token.transfer(actors[2], SUPPLY / 100);
        token.transfer(actors[3], 1);
        vm.stopPrank();

        handler = new PolyneumHandler(token, actors);
        targetContract(address(handler));
    }

    /// @dev The fixed supply never changes, whatever anyone does.
    function invariant_totalSupplyIsFixed() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
    }

    /// @dev Conservation: the balances of every address that was ever a party to a call sum to the
    ///      supply. Nothing is created, nothing is destroyed, nothing leaks to an untracked address.
    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            sum += token.balanceOf(handler.touched(i));
        }
        assertEq(sum, SUPPLY, "balances do not sum to the supply");
    }

    /// @dev The ghost accounting of successful transfers agrees with the contract, address by address.
    function invariant_ghostBalancesMatch() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.touched(i);
            assertEq(token.balanceOf(a), handler.ghostBalance(a), "ghost balance diverged");
        }
    }

    /// @dev Nobody holds more than the supply, and nobody holds more than what flowed into them.
    function invariant_noBalanceExceedsSupplyOrInflow() public view {
        uint256 n = handler.touchedCount();
        for (uint256 i = 0; i < n; i++) {
            address a = handler.touched(i);
            uint256 bal = token.balanceOf(a);
            assertLe(bal, SUPPLY, "balance above supply");
            uint256 minted = a == FACTORY ? SUPPLY : 0;
            assertEq(bal + handler.ghostSent(a), minted + handler.ghostReceived(a), "inflow accounting broken");
        }
    }

    /// @dev The ghost allowance model agrees with the contract for every actor pair.
    function invariant_allowancesMatchGhost() public view {
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < n; j++) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance diverged");
            }
        }
    }

    /// @dev The zero address can never hold anything: no mint to it, no transfer to it.
    function invariant_zeroAddressHoldsNothing() public view {
        assertEq(token.balanceOf(address(0)), 0);
    }

    /// @dev Metadata and the recorded initial holder are immutable facts.
    function invariant_metadataIsConstant() public view {
        assertEq(token.name(), "Polyneum");
        assertEq(token.symbol(), "POLYNEUM");
        assertEq(token.decimals(), 18);
        assertEq(token.initialHolder(), FACTORY);
    }

    /// @dev The sequence actually exercised something: the campaign is not vacuous.
    function invariant_campaignIsNotVacuous() public view {
        uint256 calls = handler.callsTransfer() + handler.callsApprove() + handler.callsTransferFrom();
        if (calls >= 32) {
            assertGt(handler.callsSucceeded(), 0, "no call ever succeeded");
            assertGt(handler.callsReverted(), 0, "no failure path was ever exercised");
        }
    }
}
