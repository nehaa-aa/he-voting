// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HEVoting} from "../src/HEVoting.sol";
import {BigMath} from "../src/BigMath.sol";
import {BadLength, OutOfRange} from "../src/OrProofVerifier.sol";

contract HEVotingTest is Test {
    HEVoting hv;
    address owner = address(0xA11CE);
    address other = address(0xB0B);
    address[] eligible;

    event ElectionCreated(uint256 indexed id, address owner, uint256 keyBits);
    event VotingClosed(uint256 indexed id, bytes encryptedTally);

    function setUp() public {
        hv = new HEVoting();
        eligible.push(address(0x1001));
        eligible.push(address(0x1002));
        eligible.push(address(0x1003));
    }

    // ---------- helpers ----------
    function _n(uint256 bits) internal view returns (bytes memory) {
        string memory f = bits == 512 ? "../fixtures/election_512.json" : "../fixtures/election_1024.json";
        return vm.parseJsonBytes(vm.readFile(f), ".n");
    }

    function _create(bytes memory n) internal returns (uint256 id) {
        vm.prank(owner);
        id = hv.createElection(n, eligible, 5, 3);
    }

    function _one(uint256 width) internal pure returns (bytes memory o) {
        o = new bytes(width);
        o[width - 1] = 0x01;
    }

    // ---------- creation ----------
    function _checkStored(bytes memory n, uint256 id) internal view {
        (address o, HEVoting.State st, bytes memory nn, uint256 count, uint8 size, uint8 thr) = hv.getElection(id);
        assertEq(o, owner);
        assertEq(uint8(st), uint8(HEVoting.State.Setup));
        assertEq(nn, n);
        assertEq(count, 0);
        assertEq(size, 5);
        assertEq(thr, 3);

        (bytes memory NN, bytes memory w) = hv.getModulus(id);
        assertEq(NN, BigMath.exactSquare(n), "stored N must equal n*n");
        assertEq(hv.getEncryptedTally(id), _one(2 * n.length), "tally starts at 1");

        // (1 + n) * w == 1 mod N
        bytes memory onePlusN = BigMath.add(BigMath.padLeft(n, NN.length), _one(NN.length));
        assertEq(BigMath.mulmodN(onePlusN, w, NN), _one(NN.length), "w must be (1+n)^-1 mod N");
    }

    function test_create_512() public {
        bytes memory n = _n(512);
        uint256 id = _create(n);
        assertEq(id, 1);
        _checkStored(n, id);
    }

    function test_create_1024() public {
        bytes memory n = _n(1024);
        uint256 id = _create(n);
        assertEq(id, 1);
        _checkStored(n, id);
    }

    function test_ids_increment() public {
        bytes memory n = _n(512);
        assertEq(_create(n), 1);
        assertEq(_create(n), 2);
        assertEq(hv.electionCount(), 2);
    }

    function test_created_event() public {
        bytes memory n = _n(512);
        vm.expectEmit(true, false, false, true);
        emit ElectionCreated(1, owner, 512);
        _create(n);
    }

    // ---------- bad n and parameters ----------
    function test_bad_n_length_reverts() public {
        vm.expectRevert(BadLength.selector);
        hv.createElection(new bytes(96), eligible, 5, 3);
        vm.expectRevert(BadLength.selector);
        hv.createElection(new bytes(63), eligible, 5, 3);
    }

    function test_n_top_bit_clear_reverts() public {
        bytes memory bad = bytes.concat(_n(512));
        bad[0] = bytes1(uint8(bad[0]) & 0x7f);
        vm.expectRevert(OutOfRange.selector);
        hv.createElection(bad, eligible, 5, 3);
    }

    function test_even_n_reverts() public {
        bytes memory bad = bytes.concat(_n(512));
        bad[bad.length - 1] = bytes1(uint8(bad[bad.length - 1]) & 0xfe);
        vm.expectRevert(OutOfRange.selector);
        hv.createElection(bad, eligible, 5, 3);
    }

    function test_bad_committee_params_revert() public {
        bytes memory n = _n(512);
        vm.expectRevert(OutOfRange.selector);
        hv.createElection(n, eligible, 5, 0);
        vm.expectRevert(OutOfRange.selector);
        hv.createElection(n, eligible, 5, 6);
        vm.expectRevert(OutOfRange.selector);
        hv.createElection(n, eligible, 0, 0);
    }

    // ---------- state machine ----------
    function _state(uint256 id) internal view returns (uint8) {
        (, HEVoting.State st,,,,) = hv.getElection(id);
        return uint8(st);
    }

    function test_state_machine_happy_path() public {
        uint256 id = _create(_n(512));
        assertEq(_state(id), uint8(HEVoting.State.Setup));

        vm.prank(owner);
        hv.openVoting(id);
        assertEq(_state(id), uint8(HEVoting.State.Open));

        vm.expectEmit(true, false, false, true);
        emit VotingClosed(id, hv.getEncryptedTally(id));
        vm.prank(owner);
        hv.closeVoting(id);
        assertEq(_state(id), uint8(HEVoting.State.Closed));
    }

    function test_open_twice_reverts() public {
        uint256 id = _create(_n(512));
        vm.startPrank(owner);
        hv.openVoting(id);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.openVoting(id);
        vm.stopPrank();
    }

    function test_close_before_open_reverts() public {
        uint256 id = _create(_n(512));
        vm.prank(owner);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.closeVoting(id);
    }

    function test_open_after_close_and_close_twice_revert() public {
        uint256 id = _create(_n(512));
        vm.startPrank(owner);
        hv.openVoting(id);
        hv.closeVoting(id);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.openVoting(id);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.closeVoting(id);
        vm.stopPrank();
    }

    // ---------- access control ----------
    function test_non_owner_cannot_open_or_close() public {
        uint256 id = _create(_n(512));
        vm.prank(other);
        vm.expectRevert(HEVoting.NotOwner.selector);
        hv.openVoting(id);

        vm.prank(owner);
        hv.openVoting(id);

        vm.prank(other);
        vm.expectRevert(HEVoting.NotOwner.selector);
        hv.closeVoting(id);
    }

    function test_unknown_election_reverts() public {
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.openVoting(99);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.getEncryptedTally(99);
    }
}