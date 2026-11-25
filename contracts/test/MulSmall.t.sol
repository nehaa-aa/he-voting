// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BigMath} from "../src/BigMath.sol";

/// External wrapper so vm.expectRevert can see library reverts.
contract MulSmallHarness {
    function mulSmall(bytes memory x, uint256 s) external pure returns (bytes memory) { return BigMath.mulSmall(x, s); }
    function increment(bytes memory x) external pure returns (bytes memory) { return BigMath.increment(x); }
}

contract MulSmallTest is Test {
    MulSmallHarness h;
    uint256 constant MAX = type(uint256).max;

    function setUp() public { h = new MulSmallHarness(); }

    function _w2(uint256 hi, uint256 lo) internal pure returns (bytes memory) {
        return abi.encodePacked(hi, lo);
    }

    // ---------- mulSmall, hand-made ----------
    function test_mulSmall_known_values() public pure {
        assertEq(BigMath.mulSmall(_w2(0, 7), 6), _w2(0, 42));
        assertEq(BigMath.mulSmall(_w2(0, MAX), 2), _w2(1, MAX - 1)); // carry into the next word
        assertEq(BigMath.mulSmall(_w2(0, MAX), MAX), _w2(MAX - 1, 1)); // (2^256-1)^2
        assertEq(BigMath.mulSmall(_w2(5, 9), 0), _w2(0, 0));
        assertEq(BigMath.mulSmall(_w2(5, 9), 1), _w2(5, 9));
        assertEq(BigMath.mulSmall(_w2(0, 0), MAX), _w2(0, 0));
    }

    function test_mulSmall_overflow_reverts() public {
        vm.expectRevert(BigMath.Overflow.selector);
        h.mulSmall(_w2(1 << 255, 0), 2); // 2^511 * 2 = 2^512
        vm.expectRevert(BigMath.Overflow.selector);
        h.mulSmall(_w2(MAX, MAX), 2);
        // and the largest product that still fits does not revert
        assertEq(BigMath.mulSmall(_w2((1 << 255) - 1, MAX), 2), _w2(MAX, MAX - 1));
    }

    function test_mulSmall_bad_length_reverts() public {
        vm.expectRevert(BigMath.BadLength.selector);
        h.mulSmall(hex"0102", 3);
        vm.expectRevert(BigMath.BadLength.selector);
        h.mulSmall("", 3);
    }

    // ---------- mulSmall, fuzz against the EVM's own multiplication ----------
    function testFuzz_mulSmall_single_word(uint128 x, uint128 s) public pure {
        bytes memory r = BigMath.mulSmall(abi.encodePacked(uint256(x)), uint256(s));
        assertEq(abi.decode(r, (uint256)), uint256(x) * uint256(s));
    }

    function testFuzz_mulSmall_two_words_vs_mulmod(uint256 hi, uint256 lo, uint256 s) public pure {
        bytes memory r;
        // result words of (hi,lo)*s modulo 2^512, compared via mulmod on the low word
        // and on the whole value mod (2^256 - 1)
        unchecked {
            bool fits;
            // hi * s must fit in 256 bits, together with the carry from lo * s
            uint256 mmHi = mulmod(hi, s, MAX);
            uint256 loProd = hi * s;
            uint256 hiHi = mmHi - loProd - (mmHi < loProd ? 1 : 0);
            fits = hiHi == 0 && (s == 0 || loProd / s == hi);
            uint256 mmLo = mulmod(lo, s, MAX);
            uint256 lowWord = lo * s;
            uint256 carry = mmLo - lowWord - (mmLo < lowWord ? 1 : 0);
            if (!fits || loProd + carry < loProd) return; // would overflow 512 bits: skip
            r = BigMath.mulSmall(_w2(hi, lo), s);
            assertEq(uint256(bytes32(_slice(r, 32))), lowWord);
            assertEq(uint256(bytes32(_slice(r, 0))), loProd + carry);
        }
    }

    function _slice(bytes memory b, uint256 offset) internal pure returns (bytes memory out) {
        out = new bytes(32);
        for (uint256 i = 0; i < 32; i++) out[i] = b[offset + i];
    }

    // ---------- increment ----------
    function test_increment() public pure {
        assertEq(BigMath.increment(_w2(0, 0)), _w2(0, 1));
        assertEq(BigMath.increment(_w2(0, MAX)), _w2(1, 0)); // carry across words
        assertEq(BigMath.increment(_w2(7, 41)), _w2(7, 42));
        assertEq(BigMath.increment(_w2(MAX, MAX - 1)), _w2(MAX, MAX));
    }

    function test_increment_overflow_and_length_revert() public {
        vm.expectRevert(BigMath.Overflow.selector);
        h.increment(_w2(MAX, MAX));
        vm.expectRevert(BigMath.BadLength.selector);
        h.increment(hex"01");
    }

    // ---------- the finalizeTally shape: Y = s * n + 1 ----------
    function _y(bytes memory n, uint256 s) internal pure returns (bytes memory) {
        return BigMath.increment(BigMath.mulSmall(BigMath.padLeft(n, 2 * n.length), s));
    }

    function test_Y_for_total_zero_is_one() public view {
        bytes memory n = vm.parseJsonBytes(vm.readFile("../fixtures/election_512.json"), ".n");
        bytes memory y = _y(n, 0);
        bytes memory one = new bytes(2 * n.length);
        one[one.length - 1] = 0x01;
        assertEq(y, one);
    }

    // ---------- Rust vectors ----------
    function _vectors(string memory file) internal {
        string memory j = vm.readFile(file);
        for (uint256 i = 0; i < 9; i++) {
            string memory base = string.concat(".bigMathVectors.mulSmall[", vm.toString(i), "].");
            bytes memory x = vm.parseJsonBytes(j, string.concat(base, "x"));
            uint256 s = uint256(vm.parseJsonBytes32(j, string.concat(base, "s")));
            bytes memory want = vm.parseJsonBytes(j, string.concat(base, "out"));
            uint256 g = gasleft();
            bytes memory got = BigMath.mulSmall(x, s);
            g -= gasleft();
            emit log_named_uint(string.concat("mulSmall ", vm.toString(i), " gas"), g);
            assertEq(got, want, string.concat("mulSmall vector ", vm.toString(i)));
        }
    }

    function test_vectors_512() public { _vectors("../fixtures/election_512.json"); }
    function test_vectors_1024() public { _vectors("../fixtures/election_1024.json"); }
}