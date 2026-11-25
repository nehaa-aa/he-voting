// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BigMath} from "./BigMath.sol";

struct Proof {
    bytes a0;
    bytes a1;
    bytes z0;
    bytes z1;
    uint128 e0;
    uint128 e1;
}

error BadLength();
error OutOfRange();
error InvalidChallenge();
error InvalidProof(uint8 branch);

/// Checks "c encrypts 0 or 1" (spec 2.3 / 5.5 steps 2-6). Reverts on any failure.
library OrProofVerifier {
    function verify(
        bytes memory n,
        bytes memory N,
        bytes memory w,
        uint256 electionId,
        address voter,
        bytes memory c,
        Proof memory p
    ) internal view {
        _checkShape(n, N, c, p);
        _checkChallenge(n, electionId, voter, c, p);
        _checkBranches(n, N, w, c, p);
    }

    // step 2 (lengths) and step 3 (ranges)
    function _checkShape(bytes memory n, bytes memory N, bytes memory c, Proof memory p) private pure {
        uint256 k = n.length;
        if (
            N.length != 2 * k || c.length != 2 * k || p.a0.length != 2 * k || p.a1.length != 2 * k
                || p.z0.length != k || p.z1.length != k
        ) revert BadLength();
        if (!_in(c, N) || !_in(p.a0, N) || !_in(p.a1, N) || !_in(p.z0, n) || !_in(p.z1, n)) {
            revert OutOfRange();
        }
    }

    // step 4: H = low 128 bits of keccak256(id || voter || n || c || a0 || a1)
    function _checkChallenge(bytes memory n, uint256 electionId, address voter, bytes memory c, Proof memory p)
        private
        pure
    {
        uint128 h = uint128(uint256(keccak256(abi.encodePacked(electionId, voter, n, c, p.a0, p.a1))));
        uint128 sum;
        unchecked {
            sum = p.e0 + p.e1; // mod 2^128
        }
        if (sum != h) revert InvalidChallenge();
    }

    // steps 5-6: y0 = c, y1 = c*w mod N, then z_i^n == a_i * y_i^e_i mod N
    function _checkBranches(bytes memory n, bytes memory N, bytes memory w, bytes memory c, Proof memory p)
        private
        view
    {
        if (!_holds(n, N, c, p.a0, p.z0, p.e0)) revert InvalidProof(0);
        if (!_holds(n, N, BigMath.mulmodN(c, w, N), p.a1, p.z1, p.e1)) revert InvalidProof(1);
    }

    function _holds(bytes memory n, bytes memory N, bytes memory y, bytes memory a, bytes memory z, uint128 e)
        private
        view
        returns (bool)
    {
        bytes memory lhs = BigMath.modexp(z, n, N);
        bytes memory rhs = BigMath.mulmodN(a, BigMath.modexp(y, abi.encodePacked(e), N), N);
        return keccak256(lhs) == keccak256(rhs);
    }

    function _in(bytes memory x, bytes memory bound) private pure returns (bool) {
        return !_isZero(x) && BigMath.lt(x, bound);
    }

    function _isZero(bytes memory x) private pure returns (bool) {
        uint256 words = x.length / 32;
        for (uint256 i = 0; i < words; i++) {
            uint256 v;
            assembly ("memory-safe") {
                v := mload(add(add(x, 0x20), shl(5, i)))
            }
            if (v != 0) return false;
        }
        return true;
    }
}