// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BigMath} from "../src/BigMath.sol";
import {
    OrProofVerifier, Proof, BadLength, OutOfRange, InvalidChallenge, InvalidProof
} from "../src/OrProofVerifier.sol";

struct Args {
    bytes n;
    bytes N;
    bytes w;
    uint256 id;
    address voter;
    bytes c;
    Proof p;
}

/// External wrapper so reverts are visible to expectRevert / try-catch.
contract VerifierHarness {
    function verify(Args memory a) external view {
        OrProofVerifier.verify(a.n, a.N, a.w, a.id, a.voter, a.c, a.p);
    }
}

contract OrProofVerifierTest is Test {
    VerifierHarness h;
    string json;
    bytes n;
    bytes bigN;
    bytes w;
    uint256 id;

    function setUp() public {
        h = new VerifierHarness();
    }

    // ---------- loading ----------
    function _load(string memory file) internal {
        json = vm.readFile(file);
        n = vm.parseJsonBytes(json, ".n");
        bigN = BigMath.exactSquare(n);
        w = _w(n, bigN);
        id = uint256(vm.parseJsonBytes32(json, ".electionId"));
    }

    /// w = N - n + 1 = N - (n - 1); n is odd so n - 1 just clears the last bit.
    function _w(bytes memory nn, bytes memory NN) internal pure returns (bytes memory) {
        bytes memory nm1 = BigMath.padLeft(nn, NN.length);
        nm1[nm1.length - 1] = bytes1(uint8(nm1[nm1.length - 1]) & 0xfe);
        return BigMath.sub(NN, nm1);
    }

    function _u128(bytes memory b) internal pure returns (uint128) {
        require(b.length == 16, "e must be 16 bytes");
        return uint128(bytes16(b));
    }

    function _proof(string memory base) internal view returns (Proof memory p) {
        p.a0 = vm.parseJsonBytes(json, string.concat(base, ".a0"));
        p.a1 = vm.parseJsonBytes(json, string.concat(base, ".a1"));
        p.z0 = vm.parseJsonBytes(json, string.concat(base, ".z0"));
        p.z1 = vm.parseJsonBytes(json, string.concat(base, ".z1"));
        p.e0 = _u128(vm.parseJsonBytes(json, string.concat(base, ".e0")));
        p.e1 = _u128(vm.parseJsonBytes(json, string.concat(base, ".e1")));
    }

    function _args(string memory base) internal view returns (Args memory a) {
        a.n = n;
        a.N = bigN;
        a.w = w;
        a.id = id;
        a.voter = vm.parseJsonAddress(json, string.concat(base, ".voter"));
        a.c = vm.parseJsonBytes(json, string.concat(base, ".c"));
        a.p = _proof(string.concat(base, ".proof"));
    }

    function _sel(bytes memory err) internal pure returns (bytes4 s) {
        assembly {
            s := mload(add(err, 32))
        }
    }

    /// want == 0 means "must verify"; otherwise the expected error selector.
    function _run(string memory base, bytes4 want) internal {
        Args memory a = _args(base);
        uint256 g = gasleft();
        try h.verify(a) {
            g -= gasleft();
            assertEq(bytes32(want), bytes32(0), string.concat("expected a revert: ", base));
            emit log_named_uint(string.concat("verify gas ", base), g);
        } catch (bytes memory err) {
            assertEq(bytes32(_sel(err)), bytes32(want), string.concat("wrong error: ", base));
        }
    }

    function _want(string memory reason) internal pure returns (bytes4) {
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

    // ---------- fixture ballots ----------
    function _valid(string memory file) internal {
        _load(file);
        for (uint256 i = 0; i < 10; i++) {
            _run(string.concat(".validBallots[", vm.toString(i), "]"), bytes4(0));
        }
    }

    function _invalid(string memory file) internal {
        _load(file);
        for (uint256 i = 0; i < 7; i++) {
            string memory base = string.concat(".invalidBallots[", vm.toString(i), "]");
            string memory reason = vm.parseJsonString(json, string.concat(base, ".reason"));
            _run(base, _want(reason));
        }
    }

    function test_valid_ballots_512() public { _valid("../fixtures/election_512.json"); }
    function test_valid_ballots_1024() public { _valid("../fixtures/election_1024.json"); }
    function test_invalid_ballots_512() public { _invalid("../fixtures/election_512.json"); }
    function test_invalid_ballots_1024() public { _invalid("../fixtures/election_1024.json"); }

    // ---------- replay and range checks ----------
    function test_same_ballot_other_election_reverts() public {
        _load("../fixtures/election_512.json");
        Args memory a = _args(".validBallots[0]");
        a.id = id + 1;
        vm.expectRevert(InvalidChallenge.selector);
        h.verify(a);
    }

    function test_zero_z_is_out_of_range() public {
        _load("../fixtures/election_512.json");
        Args memory a = _args(".validBallots[0]");
        a.p.z0 = new bytes(n.length);
        vm.expectRevert(OutOfRange.selector);
        h.verify(a);
    }

    function test_c_equal_to_N_is_out_of_range() public {
        _load("../fixtures/election_512.json");
        Args memory a = _args(".validBallots[0]");
        a.c = bigN;
        vm.expectRevert(OutOfRange.selector);
        h.verify(a);
    }

}