// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HEVoting} from "../src/HEVoting.sol";
import {Proof} from "../src/OrProofVerifier.sol";

contract CastVoteTest is Test {
    HEVoting hv;
    address owner = address(0xA11CE);
    string json;
    uint256 id;

    event BallotCast(uint256 indexed id, address indexed voter, bytes c);

    function _setup(string memory file) internal {
        hv = new HEVoting();
        json = vm.readFile(file);
        bytes memory n = vm.parseJsonBytes(json, ".n");

        address[] memory el = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            el[i] = vm.parseJsonAddress(json, string.concat(".validBallots[", vm.toString(i), "].voter"));
        }

        vm.startPrank(owner);
        id = hv.createElection(n, el, 5, 3);
        hv.openVoting(id);
        vm.stopPrank();
        assertEq(id, uint256(vm.parseJsonBytes32(json, ".electionId")), "fixture election id must match");
    }

    function _b(uint256 i) internal pure returns (string memory) {
        return string.concat(".validBallots[", vm.toString(i), "]");
    }

    function _proof(uint256 i) internal view returns (Proof memory p) {
        string memory b = string.concat(_b(i), ".proof");
        p.a0 = vm.parseJsonBytes(json, string.concat(b, ".a0"));
        p.a1 = vm.parseJsonBytes(json, string.concat(b, ".a1"));
        p.z0 = vm.parseJsonBytes(json, string.concat(b, ".z0"));
        p.z1 = vm.parseJsonBytes(json, string.concat(b, ".z1"));
        p.e0 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, ".e0"))));
        p.e1 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, ".e1"))));
    }

    function _cast(uint256 i) internal returns (uint256 gasUsed) {
        address voter = vm.parseJsonAddress(json, string.concat(_b(i), ".voter"));
        bytes memory c = vm.parseJsonBytes(json, string.concat(_b(i), ".c"));
        Proof memory p = _proof(i);
        vm.prank(voter);
        uint256 g = gasleft();
        hv.castVote(id, c, p);
        gasUsed = g - gasleft();
    }

    function _firstBallotThenAll() internal {
        // after one valid ballot the tally equals that ballot's c
        uint256 g0 = _cast(0);
        assertEq(hv.getEncryptedTally(id), vm.parseJsonBytes(json, string.concat(_b(0), ".c")), "tally == c0");
        emit log_named_uint("castVote gas (first ballot)", g0);

        // after all valid ballots it is byte-equal to expectedEncryptedTally
        uint256 total = g0;
        for (uint256 i = 1; i < 10; i++) {
            total += _cast(i);
        }
        emit log_named_uint("castVote gas (average of 10)", total / 10);

        assertEq(
            hv.getEncryptedTally(id),
            vm.parseJsonBytes(json, ".expectedEncryptedTally"),
            "on-chain tally must equal expectedEncryptedTally"
        );
        (,,, uint256 count,,) = hv.getElection(id);
        assertEq(count, 10);
    }

    function test_all_valid_ballots_512() public {
        _setup("../fixtures/election_512.json");
        _firstBallotThenAll();
    }

    function test_all_valid_ballots_1024() public {
        _setup("../fixtures/election_1024.json");
        _firstBallotThenAll();
    }

    function test_ballotcast_event_carries_ciphertext() public {
        _setup("../fixtures/election_512.json");
        address voter = vm.parseJsonAddress(json, string.concat(_b(0), ".voter"));
        bytes memory c = vm.parseJsonBytes(json, string.concat(_b(0), ".c"));
        vm.expectEmit(true, true, false, true);
        emit BallotCast(id, voter, c);
        _cast(0);
    }

    function test_close_publishes_final_tally() public {
        _setup("../fixtures/election_512.json");
        for (uint256 i = 0; i < 10; i++) _cast(i);
        vm.prank(owner);
        hv.closeVoting(id);
        assertEq(hv.getEncryptedTally(id), vm.parseJsonBytes(json, ".expectedEncryptedTally"));
    }
}