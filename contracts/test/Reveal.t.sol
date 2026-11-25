// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HEVoting} from "../src/HEVoting.sol";
import {Proof, BadLength, OutOfRange} from "../src/OrProofVerifier.sol";

contract RevealTest is Test {
    string constant F512 = "../fixtures/election_512.json";
    string constant F1024 = "../fixtures/election_1024.json";
    string constant MNEMONIC = "test test test test test test test test test test test junk";

    HEVoting hv;
    address owner = address(0xA11CE);
    string json;
    uint256 id;
    address[] voters;
    address[] committee;

    event PartialSubmitted(uint256 indexed id, uint8 indexed memberIndex);
    event TallyFinalized(uint256 indexed id, uint256 total);

    // ---------- loading and building ----------
    function _vb(uint256 i, string memory f) internal pure returns (string memory) {
        return string.concat(".validBallots[", vm.toString(i), "].", f);
    }

    function _proof(uint256 i) internal view returns (Proof memory p) {
        string memory b = string.concat(_vb(i, "proof"), ".");
        p.a0 = vm.parseJsonBytes(json, string.concat(b, "a0"));
        p.a1 = vm.parseJsonBytes(json, string.concat(b, "a1"));
        p.z0 = vm.parseJsonBytes(json, string.concat(b, "z0"));
        p.z1 = vm.parseJsonBytes(json, string.concat(b, "z1"));
        p.e0 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, "e0"))));
        p.e1 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, "e1"))));
    }

    function _load(string memory file) internal {
        json = vm.readFile(file);
        delete voters;
        delete committee;
        for (uint256 i = 0; i < 10; i++) {
            voters.push(vm.parseJsonAddress(json, _vb(i, "voter")));
        }
        for (uint256 i = 0; i < 5; i++) {
            committee.push(vm.addr(vm.deriveKey(MNEMONIC, uint32(11 + i)))); // Anvil accounts 11..15
        }
    }

    /// Fresh contract (so the election id is 1, as the ballots require), 10 valid ballots cast, state Open.
    function _build(string memory file) internal {
        _load(file);
        hv = new HEVoting();
        bytes memory n = vm.parseJsonBytes(json, ".n");
        vm.startPrank(owner);
        id = hv.createElection(n, voters, 5, 3);
        hv.openVoting(id);
        vm.stopPrank();
        for (uint256 i = 0; i < 10; i++) {
            bytes memory c = vm.parseJsonBytes(json, _vb(i, "c"));
            Proof memory p = _proof(i);
            vm.prank(voters[i]);
            hv.castVote(id, c, p);
        }
    }

    function _setCommittee() internal {
        vm.prank(owner);
        hv.setCommittee(id, committee);
    }

    function _close() internal {
        vm.prank(owner);
        hv.closeVoting(id);
    }

    function _partial(uint8 idx) internal view returns (bytes memory) {
        return vm.parseJsonBytes(json, string.concat(".reveal.partials[", vm.toString(uint256(idx) - 1), "].value"));
    }

    function _submit(uint8 idx) internal {
        bytes memory v = _partial(idx);
        vm.prank(committee[idx - 1]);
        hv.submitPartial(id, v);
    }

    function _submitAll() internal {
        for (uint8 i = 1; i <= 5; i++) {
            _submit(i);
        }
    }

    /// Open -> committee set -> closed -> all five partials submitted.
    function _ready(string memory file) internal {
        _build(file);
        _setCommittee();
        _close();
        _submitAll();
    }

    function _total() internal view returns (uint256) {
        return vm.parseJsonUint(json, ".reveal.total");
    }

    function _idx(uint8 a, uint8 b, uint8 c) internal pure returns (uint8[] memory out) {
        out = new uint8[](3);
        out[0] = a;
        out[1] = b;
        out[2] = c;
    }

    function _subset(uint256 s) internal view returns (uint8[] memory out) {
        uint256[] memory raw = vm.parseJsonUintArray(json, string.concat(".reveal.validSubsets[", vm.toString(s), "]"));
        out = new uint8[](raw.length);
        for (uint256 i = 0; i < raw.length; i++) {
            out[i] = uint8(raw[i]);
        }
    }

    // ---------- every valid subset finalizes ----------
    function _everySubset(string memory file) internal {
        for (uint256 s = 0; s < 10; s++) {
            _ready(file);
            uint8[] memory sub = _subset(s);
            uint256 tot = _total();
            uint256 g = gasleft();
            hv.finalizeTally(id, sub, tot);
            g -= gasleft();
            emit log_named_uint(string.concat("finalizeTally gas, subset ", vm.toString(s)), g);

            (bool fin, uint256 got, uint8 cnt) = hv.getResult(id);
            assertTrue(fin);
            assertEq(got, tot);
            assertEq(cnt, 5);
            (, HEVoting.State st,,,,) = hv.getElection(id);
            assertEq(uint8(st), uint8(HEVoting.State.Finalized));
        }
    }

    function test_every_valid_subset_finalizes_512() public { _everySubset(F512); }
    function test_every_valid_subset_finalizes_1024() public { _everySubset(F1024); }

    // ---------- bad partial ----------
    function _badPartial(string memory file) internal {
        _build(file);
        _setCommittee();
        _close();
        uint8 badIdx = uint8(vm.parseJsonUint(json, ".reveal.badPartial.index"));
        assertEq(badIdx, 2);
        bytes memory bad = vm.parseJsonBytes(json, ".reveal.badPartial.value");
        for (uint8 i = 1; i <= 5; i++) {
            if (i == badIdx) {
                vm.prank(committee[i - 1]);
                hv.submitPartial(id, bad);
            } else {
                _submit(i);
            }
        }
        uint256 tot = _total();
        uint8[] memory withBad = _idx(1, 2, 3);
        uint8[] memory without = _idx(1, 3, 4);

        vm.expectRevert(HEVoting.WrongTotal.selector);
        hv.finalizeTally(id, withBad, tot);

        // a different subset of the stored partials still works
        hv.finalizeTally(id, without, tot);
        (bool fin,,) = hv.getResult(id);
        assertTrue(fin);
    }

    function test_bad_partial_512() public { _badPartial(F512); }
    function test_bad_partial_1024() public { _badPartial(F1024); }

    // ---------- wrong totals ----------
    function test_wrong_totals_revert() public {
        _ready(F512);
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();

        vm.expectRevert(HEVoting.WrongTotal.selector);
        hv.finalizeTally(id, sub, tot + 1);
        vm.expectRevert(HEVoting.WrongTotal.selector);
        hv.finalizeTally(id, sub, tot - 1);
        vm.expectRevert(HEVoting.WrongTotal.selector);
        hv.finalizeTally(id, sub, 0);
        vm.expectRevert(HEVoting.WrongTotal.selector);
        hv.finalizeTally(id, sub, 11); // above ballotCount (10)

        // none of those changed anything: the right total still works
        hv.finalizeTally(id, sub, tot);
        (bool fin, uint256 got,) = hv.getResult(id);
        assertTrue(fin);
        assertEq(got, tot);
    }

    // ---------- indices ----------
    function test_bad_indices_revert() public {
        _ready(F512);
        uint256 tot = _total();
        uint8[] memory unsorted = _idx(2, 1, 3);
        uint8[] memory dupFirst = _idx(1, 1, 2);
        uint8[] memory dupLast = _idx(1, 2, 2);
        uint8[] memory tooHigh = _idx(1, 2, 6);
        uint8[] memory hasZero = _idx(0, 1, 2);
        uint8[] memory two = new uint8[](2);
        two[0] = 1;
        two[1] = 2;
        uint8[] memory four = new uint8[](4);
        for (uint8 i = 0; i < 4; i++) {
            four[i] = i + 1;
        }
        bytes4 sel = HEVoting.BadIndices.selector;

        vm.expectRevert(sel);
        hv.finalizeTally(id, unsorted, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, dupFirst, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, dupLast, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, tooHigh, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, hasZero, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, two, tot);
        vm.expectRevert(sel);
        hv.finalizeTally(id, four, tot);
    }

    function test_index_with_no_submitted_partial_reverts() public {
        _build(F512);
        _setCommittee();
        _close();
        _submit(1);
        _submit(2);
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        vm.expectRevert(HEVoting.NotEnoughPartials.selector);
        hv.finalizeTally(id, sub, tot);
    }

    // ---------- submitPartial access and validation ----------
    function test_non_member_cannot_submit() public {
        _build(F512);
        _setCommittee();
        _close();
        bytes memory v = _partial(1);
        vm.prank(address(0xBAD));
        vm.expectRevert(HEVoting.NotCommittee.selector);
        hv.submitPartial(id, v);
    }

    function test_second_submission_reverts() public {
        _build(F512);
        _setCommittee();
        _close();
        _submit(1);
        bytes memory v = _partial(1);
        vm.prank(committee[0]);
        vm.expectRevert(HEVoting.AlreadySubmitted.selector);
        hv.submitPartial(id, v);
    }

    function test_submit_before_close_reverts() public {
        _build(F512);
        _setCommittee();
        bytes memory v = _partial(1);
        vm.prank(committee[0]);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.submitPartial(id, v);
    }

    function test_bad_partial_values_revert() public {
        _build(F512);
        _setCommittee();
        _close();
        (bytes memory NN,) = hv.getModulus(id);
        bytes memory shortV = new bytes(NN.length - 32);
        bytes memory zeroV = new bytes(NN.length);

        vm.prank(committee[0]);
        vm.expectRevert(BadLength.selector);
        hv.submitPartial(id, shortV);
        vm.prank(committee[0]);
        vm.expectRevert(OutOfRange.selector);
        hv.submitPartial(id, zeroV);
        vm.prank(committee[0]);
        vm.expectRevert(OutOfRange.selector);
        hv.submitPartial(id, NN); // value == N is out of range

        (,, uint8 cnt) = hv.getResult(id);
        assertEq(cnt, 0, "rejected submissions must not be stored");
    }

    // ---------- finalize state rules ----------
    function test_finalize_before_close_reverts() public {
        _build(F512);
        _setCommittee();
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.finalizeTally(id, sub, tot);
    }

    function test_finalize_twice_reverts() public {
        _ready(F512);
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        hv.finalizeTally(id, sub, tot);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.finalizeTally(id, sub, tot);
    }

    function test_committee_not_set_reverts() public {
        _build(F512);
        _close();
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        bytes memory v = _partial(1);

        vm.expectRevert(HEVoting.CommitteeNotSet.selector);
        hv.finalizeTally(id, sub, tot);

        vm.prank(committee[0]);
        vm.expectRevert(HEVoting.CommitteeNotSet.selector);
        hv.submitPartial(id, v);
    }

    function test_everything_blocked_after_finalize() public {
        _ready(F512);
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        hv.finalizeTally(id, sub, tot);

        bytes memory c = vm.parseJsonBytes(json, _vb(0, "c"));
        Proof memory p = _proof(0);
        bytes memory v = _partial(1);

        vm.prank(voters[0]);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.castVote(id, c, p);
        vm.prank(owner);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.closeVoting(id);
        vm.prank(owner);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.openVoting(id);
        vm.prank(committee[0]);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.submitPartial(id, v);
        vm.prank(owner);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.setCommittee(id, committee);
    }

    // ---------- setCommittee ----------
    function test_set_committee_access_and_validation() public {
        _build(F512);

        vm.prank(address(0xBAD));
        vm.expectRevert(HEVoting.NotOwner.selector);
        hv.setCommittee(id, committee);

        address[] memory four = new address[](4);
        for (uint256 i = 0; i < 4; i++) {
            four[i] = committee[i];
        }
        vm.prank(owner);
        vm.expectRevert(BadLength.selector);
        hv.setCommittee(id, four);

        address[] memory dup = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            dup[i] = committee[i];
        }
        dup[4] = committee[0];
        vm.prank(owner);
        vm.expectRevert(OutOfRange.selector);
        hv.setCommittee(id, dup);

        dup[4] = address(0);
        vm.prank(owner);
        vm.expectRevert(OutOfRange.selector);
        hv.setCommittee(id, dup);

        _close();
        vm.prank(owner);
        vm.expectRevert(HEVoting.WrongState.selector);
        hv.setCommittee(id, committee);
    }

    function test_set_committee_can_be_replaced_while_open() public {
        _build(F512);
        _setCommittee();
        address[] memory second = new address[](5);
        for (uint256 i = 0; i < 4; i++) {
            second[i] = committee[i];
        }
        second[4] = address(0xC0FFEE);
        vm.prank(owner);
        hv.setCommittee(id, second);
        _close();

        bytes memory v5 = _partial(5);
        vm.prank(committee[4]); // the old member 5 is no longer a member
        vm.expectRevert(HEVoting.NotCommittee.selector);
        hv.submitPartial(id, v5);

        vm.prank(address(0xC0FFEE));
        vm.expectEmit(true, true, false, true);
        emit PartialSubmitted(id, 5);
        hv.submitPartial(id, v5);
    }

    function test_committee_size_above_max_reverts() public {
        _load(F512);
        hv = new HEVoting();
        bytes memory n = vm.parseJsonBytes(json, ".n");
        vm.prank(owner);
        uint256 eid = hv.createElection(n, voters, 21, 3);
        address[] memory many = new address[](21);
        for (uint256 i = 0; i < 21; i++) {
            many[i] = address(uint160(0x1000 + i));
        }
        vm.prank(owner);
        vm.expectRevert(OutOfRange.selector);
        hv.setCommittee(eid, many);
    }

    // ---------- events, getResult, committee file ----------
    function test_events_and_get_result() public {
        _build(F512);
        _setCommittee();
        _close();

        (bool fin, uint256 t0, uint8 cnt) = hv.getResult(id);
        assertFalse(fin);
        assertEq(t0, 0);
        assertEq(cnt, 0);

        bytes memory v = _partial(3);
        vm.prank(committee[2]);
        vm.expectEmit(true, true, false, true);
        emit PartialSubmitted(id, 3);
        hv.submitPartial(id, v);
        (,, cnt) = hv.getResult(id);
        assertEq(cnt, 1);

        _submit(1);
        _submit(2);
        uint8[] memory sub = _idx(1, 2, 3);
        uint256 tot = _total();
        vm.expectEmit(true, false, false, true);
        emit TallyFinalized(id, tot);
        hv.finalizeTally(id, sub, tot);
    }

    function test_committee_file_matches_anvil_accounts() public view {
        address[] memory fromFile = vm.parseJsonAddressArray(vm.readFile("../fixtures/committee.json"), "$");
        assertEq(fromFile.length, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(fromFile[i], vm.addr(vm.deriveKey(MNEMONIC, uint32(11 + i))));
        }
    }
}