// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HEVoting} from "../src/HEVoting.sol";
import {Proof, BadLength, InvalidChallenge, InvalidProof} from "../src/OrProofVerifier.sol";

contract NegativeTest is Test {
    string constant F512 = "../fixtures/election_512.json";
    string constant F1024 = "../fixtures/election_1024.json";

    HEVoting hv;
    address owner = address(0xA11CE);
    string json;
    uint256 id;
    address[] voters;

    // ---------- setup and loading ----------
    function _setup(string memory file, bool open) internal {
        hv = new HEVoting();
        json = vm.readFile(file);
        delete voters;
        for (uint256 i = 0; i < 10; i++) {
            voters.push(vm.parseJsonAddress(json, string.concat(_valid(i), ".voter")));
        }
        vm.startPrank(owner);
        id = hv.createElection(vm.parseJsonBytes(json, ".n"), voters, 5, 3);
        if (open) hv.openVoting(id);
        vm.stopPrank();
    }

    function _valid(uint256 i) internal pure returns (string memory) {
        return string.concat(".validBallots[", vm.toString(i), "]");
    }

    function _invalid(uint256 i) internal pure returns (string memory) {
        return string.concat(".invalidBallots[", vm.toString(i), "]");
    }

    function _proof(string memory base) internal view returns (Proof memory p) {
        string memory b = string.concat(base, ".proof");
        p.a0 = vm.parseJsonBytes(json, string.concat(b, ".a0"));
        p.a1 = vm.parseJsonBytes(json, string.concat(b, ".a1"));
        p.z0 = vm.parseJsonBytes(json, string.concat(b, ".z0"));
        p.z1 = vm.parseJsonBytes(json, string.concat(b, ".z1"));
        p.e0 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, ".e0"))));
        p.e1 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, ".e1"))));
    }

    /// Submit the fixture ballot at `base` as `sender` to election `eid`.
    /// Returns whether it was accepted, and the revert selector if not.
    function _try(address sender, uint256 eid, string memory base) internal returns (bool ok, bytes4 sel) {
        bytes memory c = vm.parseJsonBytes(json, string.concat(base, ".c"));
        Proof memory p = _proof(base);
        vm.prank(sender);
        try hv.castVote(eid, c, p) {
            ok = true;
        } catch (bytes memory err) {
            sel = err.length >= 4 ? bytes4(err) : bytes4(0);
        }
    }

    function _expectReject(address sender, uint256 eid, string memory base, bytes4 want, string memory what)
        internal
    {
        (bool ok, bytes4 sel) = _try(sender, eid, base);
        assertFalse(ok, string.concat("was accepted: ", what));
        assertEq(bytes32(sel), bytes32(want), string.concat("wrong error: ", what));
    }

    function _wantFor(string memory reason) internal pure returns (bytes4) {
        bytes32 r = keccak256(bytes(reason));
        if (r == keccak256("encrypts_2") || r == keccak256("encrypts_5") || r == keccak256("tampered_z1")) {
            return InvalidProof.selector;
        }
        if (r == keccak256("tampered_a0") || r == keccak256("tampered_e0") || r == keccak256("wrong_voter_binding")) {
            return InvalidChallenge.selector;
        }
        if (r == keccak256("wrong_length")) return BadLength.selector;
        revert("unknown invalid-ballot reason");
    }

    function _checkInvalid(uint256 i) internal {
        string memory base = _invalid(i);
        string memory reason = vm.parseJsonString(json, string.concat(base, ".reason"));
        address sender = vm.parseJsonAddress(json, string.concat(base, ".voter"));
        _expectReject(sender, id, base, _wantFor(reason), reason);
    }

    // ---------- fixture invalid ballots, through castVote ----------
    function _allInvalid(string memory file) internal {
        _setup(file, true);
        bytes memory before = hv.getEncryptedTally(id);
        for (uint256 i = 0; i < 7; i++) {
            _checkInvalid(i);
        }
        // no rejected ballot changed the tally or the count
        assertEq(hv.getEncryptedTally(id), before, "tally changed");
        (,,, uint256 count,,) = hv.getElection(id);
        assertEq(count, 0);
        // and no voter's vote was used up by a rejected ballot
        (bool ok,) = _try(voters[0], id, _valid(0));
        assertTrue(ok);
    }

    function test_invalid_ballots_revert_512() public { _allInvalid(F512); }
    function test_invalid_ballots_revert_1024() public { _allInvalid(F1024); }

    // ---------- replay ----------
    function test_ballot_replayed_by_another_voter_reverts() public {
        _setup(F512, true);
        _expectReject(voters[1], id, _valid(0), InvalidChallenge.selector, "voter A ballot by voter B");
        // voter B can still vote with their own ballot
        (bool ok,) = _try(voters[1], id, _valid(1));
        assertTrue(ok);
    }

    function test_same_ballot_in_another_election_reverts() public {
        _setup(F512, true);
        vm.startPrank(owner);
        uint256 id2 = hv.createElection(vm.parseJsonBytes(json, ".n"), voters, 5, 3);
        hv.openVoting(id2);
        vm.stopPrank();
        assertEq(id2, id + 1);

        _expectReject(voters[0], id2, _valid(0), InvalidChallenge.selector, "ballot from election 1 in election 2");
        // it still works in the election it was made for
        (bool ok,) = _try(voters[0], id, _valid(0));
        assertTrue(ok);
    }

    // ---------- state and access ----------
    function test_double_vote_reverts() public {
        _setup(F512, true);
        (bool ok,) = _try(voters[0], id, _valid(0));
        assertTrue(ok);
        _expectReject(voters[0], id, _valid(0), HEVoting.AlreadyVoted.selector, "second vote");
    }

    function test_non_eligible_address_reverts() public {
        _setup(F512, true);
        _expectReject(address(0xBAD), id, _valid(0), HEVoting.NotEligible.selector, "not on the whitelist");
    }

    function test_vote_before_open_reverts() public {
        _setup(F512, false);
        _expectReject(voters[0], id, _valid(0), HEVoting.WrongState.selector, "vote in Setup");
    }

    function test_vote_after_close_reverts() public {
        _setup(F512, true);
        (bool ok,) = _try(voters[0], id, _valid(0));
        assertTrue(ok);
        vm.prank(owner);
        hv.closeVoting(id);
        _expectReject(voters[1], id, _valid(1), HEVoting.WrongState.selector, "vote after close");
    }
}