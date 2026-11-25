// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Big-number helpers on big-endian byte arrays, built on the modexp precompile (0x05).
/// Arithmetic helpers need equal lengths that are multiples of 32 bytes.
library BigMath {
    error BadLength();
    error Underflow();
    error Overflow();
    error ModexpFailed();

    // ---------- word access ----------
    function _get(bytes memory b, uint256 i) private pure returns (uint256 v) {
        assembly ("memory-safe") {
            v := mload(add(add(b, 0x20), shl(5, i)))
        }
    }

    function _set(bytes memory b, uint256 i, uint256 v) private pure {
        assembly ("memory-safe") {
            mstore(add(add(b, 0x20), shl(5, i)), v)
        }
    }

    function _same(bytes memory a, bytes memory b) private pure returns (uint256 words) {
        if (a.length != b.length || a.length == 0 || a.length % 32 != 0) revert BadLength();
        words = a.length / 32;
    }

    // ---------- precompile wrappers ----------
    /// base^exp mod mod, result has mod.length bytes.
    function modexp(bytes memory base, bytes memory exp, bytes memory mod)
        internal
        view
        returns (bytes memory out)
    {
        uint256 ml = mod.length;
        bytes memory input = abi.encodePacked(base.length, exp.length, ml, base, exp, mod);
        out = new bytes(ml);
        bool ok;
        assembly ("memory-safe") {
            ok := staticcall(gas(), 0x05, add(input, 0x20), mload(input), add(out, 0x20), ml)
        }
        if (!ok) revert ModexpFailed();
    }

    /// x^2 with no reduction. Output has 2 * x.length bytes.
    /// Uses modexp(x, 2, 2^(16 * len)), the modulus being 0x01 followed by 2*len zero bytes.
    function exactSquare(bytes memory x) internal view returns (bytes memory r) {
        uint256 len = x.length;
        if (len == 0 || len % 32 != 0) revert BadLength();
        bytes memory mod = new bytes(2 * len + 1);
        mod[0] = 0x01;
        bytes memory raw = modexp(x, hex"02", mod); // 2*len+1 bytes, first byte is 0
        r = new bytes(2 * len);
        assembly ("memory-safe") {
            let src := add(raw, 0x21) // skip length word and the leading zero byte
            let dst := add(r, 0x20)
            let end := mul(2, len)
            for { let i := 0 } lt(i, end) { i := add(i, 0x20) } {
                mstore(add(dst, i), mload(add(src, i)))
            }
        }
    }

    // ---------- comparison and linear arithmetic ----------
    function lt(bytes memory a, bytes memory b) internal pure returns (bool) {
        uint256 n = _same(a, b);
        for (uint256 i = 0; i < n; i++) {
            uint256 x = _get(a, i);
            uint256 y = _get(b, i);
            if (x != y) return x < y;
        }
        return false;
    }

    /// a - b, reverts if a < b.
    function sub(bytes memory a, bytes memory b) internal pure returns (bytes memory r) {
        uint256 n = _same(a, b);
        r = new bytes(a.length);
        uint256 borrow = 0;
        for (uint256 i = n; i > 0; i--) {
            uint256 x = _get(a, i - 1);
            uint256 y = _get(b, i - 1);
            uint256 d;
            unchecked {
                d = x - y - borrow;
                borrow = (x < y || (x == y && borrow == 1)) ? 1 : 0;
            }
            _set(r, i - 1, d);
        }
        if (borrow != 0) revert Underflow();
    }

    /// a + b, reverts on carry out of the top word.
    function add(bytes memory a, bytes memory b) internal pure returns (bytes memory r) {
        uint256 n = _same(a, b);
        r = new bytes(a.length);
        uint256 carry = 0;
        for (uint256 i = n; i > 0; i--) {
            uint256 x = _get(a, i - 1);
            uint256 y = _get(b, i - 1);
            uint256 s;
            uint256 s2;
            unchecked {
                s = x + y;
                s2 = s + carry;
                carry = (s < x || s2 < s) ? 1 : 0;
            }
            _set(r, i - 1, s2);
        }
        if (carry != 0) revert Overflow();
    }

    /// x >> 1 (same length).
    function shr1(bytes memory x) internal pure returns (bytes memory r) {
        uint256 n = x.length / 32;
        if (x.length == 0 || x.length % 32 != 0) revert BadLength();
        r = new bytes(x.length);
        uint256 carryBit = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 v = _get(x, i);
            _set(r, i, (v >> 1) | (carryBit << 255));
            carryBit = v & 1;
        }
    }

    /// Left-pad with zero bytes to `width` (both multiples of 32).
    function padLeft(bytes memory x, uint256 width) internal pure returns (bytes memory r) {
        if (x.length > width || x.length % 32 != 0 || width % 32 != 0) revert BadLength();
        r = new bytes(width);
        uint256 shift = (width - x.length) / 32;
        uint256 n = x.length / 32;
        for (uint256 i = 0; i < n; i++) {
            _set(r, shift + i, _get(x, i));
        }
    }

    // ---------- modular multiplication ----------
    /// a * b mod N. a, b and N all have the same length (a multiple of 32 bytes).
    /// 2ab = (a+b)^2 - a^2 - b^2 is computed exactly on width+32 bytes, halved, then
    /// reduced with modexp(x, 1, N). Result has N.length bytes.
    function mulmodN(bytes memory a, bytes memory b, bytes memory N)
        internal
        view
        returns (bytes memory)
    {
        uint256 w = N.length;
        if (w == 0 || w % 32 != 0 || a.length != w || b.length != w) revert BadLength();
        uint256 wide = w + 32; // room for the carry of a + b
        bytes memory pa = padLeft(a, wide);
        bytes memory pb = padLeft(b, wide);
        bytes memory s2 = exactSquare(add(pa, pb));
        bytes memory twoAB = sub(sub(s2, exactSquare(pa)), exactSquare(pb));
        return modexp(shr1(twoAB), hex"01", N);
    }

        // ---------- small multiplier and increment (Phase 2) ----------
    /// Exact x * s with the same width as x. Reverts with Overflow if it does not fit.
    function mulSmall(bytes memory x, uint256 s) internal pure returns (bytes memory r) {
        if (x.length == 0 || x.length % 32 != 0) revert BadLength();
        uint256 n = x.length / 32;
        r = new bytes(x.length);
        uint256 carry = 0;
        for (uint256 i = n; i > 0; i--) {
            uint256 a = _get(x, i - 1);
            unchecked {
                // full 512-bit product of a * s as (hi, lo)
                uint256 lo = a * s;
                uint256 mm = mulmod(a, s, type(uint256).max);
                uint256 hi = mm - lo - (mm < lo ? 1 : 0);
                // add the carry from the lower word
                uint256 sum = lo + carry;
                if (sum < lo) hi += 1;
                _set(r, i - 1, sum);
                carry = hi;
            }
        }
        if (carry != 0) revert Overflow();
    }

    /// x + 1 with the same width as x. Reverts with Overflow if x is all ones.
    function increment(bytes memory x) internal pure returns (bytes memory r) {
        if (x.length == 0 || x.length % 32 != 0) revert BadLength();
        uint256 n = x.length / 32;
        r = new bytes(x.length);
        bool carry = true;
        for (uint256 i = n; i > 0; i--) {
            uint256 v = _get(x, i - 1);
            if (carry) {
                unchecked {
                    v += 1;
                }
                carry = (v == 0);
            }
            _set(r, i - 1, v);
        }
        if (carry) revert Overflow();
    }
}