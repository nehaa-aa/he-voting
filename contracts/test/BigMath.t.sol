// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BigMath} from "../src/BigMath.sol";

/// External wrapper so vm.expectRevert can see library reverts.
contract BigMathHarness {
    function sub(bytes memory a, bytes memory b) external pure returns (bytes memory) { return BigMath.sub(a, b); }
    function add(bytes memory a, bytes memory b) external pure returns (bytes memory) { return BigMath.add(a, b); }
    function lt(bytes memory a, bytes memory b) external pure returns (bool) { return BigMath.lt(a, b); }
    function exactSquare(bytes memory x) external view returns (bytes memory) { return BigMath.exactSquare(x); }
    function mulmodN(bytes memory a, bytes memory b, bytes memory n) external view returns (bytes memory) {
        return BigMath.mulmodN(a, b, n);
    }
}

contract BigMathTest is Test {
    BigMathHarness h;
    uint256 constant MAX = type(uint256).max;

    function setUp() public { h = new BigMathHarness(); }

    function _w2(uint256 hi, uint256 lo) internal pure returns (bytes memory) {
        return abi.encodePacked(hi, lo);
    }

    // ---------- hand-made edge cases ----------
    function test_lt() public pure {
        assertFalse(BigMath.lt(_w2(1, 5), _w2(1, 5)));
        assertTrue(BigMath.lt(_w2(1, 5), _w2(1, 6)));
        assertFalse(BigMath.lt(_w2(1, 0), _w2(0, MAX))); // high word wins
        assertTrue(BigMath.lt(_w2(0, MAX), _w2(1, 0)));
    }

    function test_sub_borrows_across_words() public pure {
        assertEq(BigMath.sub(_w2(1, 0), _w2(0, 1)), _w2(0, MAX));
        assertEq(BigMath.sub(_w2(7, 7), _w2(7, 7)), _w2(0, 0));
    }

    function test_sub_underflow_reverts() public {
        vm.expectRevert(BigMath.Underflow.selector);
        h.sub(_w2(0, 1), _w2(0, 2));
    }

    function test_add_carries_and_overflows() public {
        assertEq(BigMath.add(_w2(0, MAX), _w2(0, 1)), _w2(1, 0));
        vm.expectRevert(BigMath.Overflow.selector);
        h.add(_w2(MAX, MAX), _w2(0, 1));
    }

    function test_shr1() public pure {
        assertEq(BigMath.shr1(_w2(1, 0)), _w2(0, 1 << 255));
        assertEq(BigMath.shr1(_w2(0, 6)), _w2(0, 3));
    }

    function test_bad_lengths_revert() public {
        vm.expectRevert(BigMath.BadLength.selector);
        h.lt(_w2(0, 1), abi.encodePacked(uint256(1)));
        vm.expectRevert(BigMath.BadLength.selector);
        h.exactSquare(hex"0102");
    }

    function test_exactSquare_known_values() public view {
        // 3^2 = 9 on 2 words -> 4 words
        assertEq(BigMath.exactSquare(_w2(0, 3)), abi.encodePacked(uint256(0), uint256(0), uint256(0), uint256(9)));
        // (2^512 - 1)^2 = 2^1024 - 2^513 + 1
        assertEq(
            BigMath.exactSquare(_w2(MAX, MAX)),
            abi.encodePacked(MAX, MAX - 1, uint256(0), uint256(1))
        );
        // 0 and 1
        assertEq(BigMath.exactSquare(_w2(0, 0)), abi.encodePacked(uint256(0), uint256(0), uint256(0), uint256(0)));
        assertEq(BigMath.exactSquare(_w2(0, 1)), abi.encodePacked(uint256(0), uint256(0), uint256(0), uint256(1)));
    }

    // ---------- compare mulmodN with the EVM's own mulmod (32-byte operands) ----------
    function testFuzz_mulmodN_matches_evm(uint256 a, uint256 b, uint256 n) public view {
        vm.assume(n > 1);
        bytes memory r = BigMath.mulmodN(abi.encodePacked(a), abi.encodePacked(b), abi.encodePacked(n));
        assertEq(abi.decode(r, (uint256)), mulmod(a, b, n));
    }

    // ---------- Rust vectors ----------
    function _p(string memory kind, uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".bigMathVectors.", kind, "[", vm.toString(i), "].", field);
    }

    function _vectors(string memory file) internal {
        string memory j = vm.readFile(file);

        for (uint256 i = 0; i < 8; i++) {
            bytes memory b = vm.parseJsonBytes(j, _p("modexp", i, "base"));
            bytes memory e = vm.parseJsonBytes(j, _p("modexp", i, "exp"));
            bytes memory m = vm.parseJsonBytes(j, _p("modexp", i, "mod"));
            bytes memory want = vm.parseJsonBytes(j, _p("modexp", i, "out"));
            uint256 g = gasleft();
            bytes memory got = BigMath.modexp(b, e, m);
            g -= gasleft();
            emit log_named_uint(string.concat("modexp ", vm.toString(i), " gas"), g);
            assertEq(got, want, string.concat("modexp ", vm.toString(i)));
        }

        for (uint256 i = 0; i < 6; i++) {
            bytes memory a = vm.parseJsonBytes(j, _p("mulmod", i, "a"));
            bytes memory b = vm.parseJsonBytes(j, _p("mulmod", i, "b"));
            bytes memory m = vm.parseJsonBytes(j, _p("mulmod", i, "mod"));
            bytes memory want = vm.parseJsonBytes(j, _p("mulmod", i, "out"));
            uint256 g = gasleft();
            bytes memory got = BigMath.mulmodN(a, b, m);
            g -= gasleft();
            emit log_named_uint(string.concat("mulmodN ", vm.toString(i), " gas"), g);
            assertEq(got, want, string.concat("mulmod ", vm.toString(i)));
        }

        for (uint256 i = 0; i < 7; i++) {
            bytes memory x = vm.parseJsonBytes(j, _p("exactSquare", i, "x"));
            bytes memory want = vm.parseJsonBytes(j, _p("exactSquare", i, "out"));
            uint256 g = gasleft();
            bytes memory got = BigMath.exactSquare(x);
            g -= gasleft();
            emit log_named_uint(string.concat("exactSquare ", vm.toString(i), " gas"), g);
            assertEq(got, want, string.concat("exactSquare ", vm.toString(i)));
        }
    }

    function test_vectors_512() public { _vectors("../fixtures/election_512.json"); }
    function test_vectors_1024() public { _vectors("../fixtures/election_1024.json"); }
}