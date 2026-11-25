// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BigMath} from "./BigMath.sol";
import {OrProofVerifier, Proof, BadLength, OutOfRange} from "./OrProofVerifier.sol";

contract HEVoting {
    enum State { Setup, Open, Closed, Finalized } // Finalized is new, appended last

    uint8 public constant MAX_COMMITTEE = 20;

    struct Election {
        address owner;
        State state;
        uint8 committeeSize;
        uint8 threshold;
        uint256 ballotCount;
        bytes n;
        bytes N;
        bytes w; // N - n + 1 = (1 + n)^-1 mod N
        bytes tally;
        mapping(address => bool) eligible;
        mapping(address => bool) voted;
        mapping(address => bytes32) ballotHash;
        // ---- reveal (Phase 2) ----
        bool committeeSet;
        address[] members;
        mapping(address => uint8) memberIndex; // 1-based, 0 = not a member
        mapping(uint8 => bytes) partials;
        mapping(uint8 => bool) submitted;
        uint8 partialCount;
        uint256 total;
    }

    mapping(uint256 => Election) private elections;
    uint256 public electionCount;

    event ElectionCreated(uint256 indexed id, address owner, uint256 keyBits);
    event BallotCast(uint256 indexed id, address indexed voter, bytes c);
    event VotingClosed(uint256 indexed id, bytes encryptedTally);
    event PartialSubmitted(uint256 indexed id, uint8 indexed memberIndex);
    event TallyFinalized(uint256 indexed id, uint256 total);

    error NotOwner();
    error WrongState();
    error NotEligible();
    error AlreadyVoted();
    error NotCommittee();
    error AlreadySubmitted();
    error CommitteeNotSet();
    error BadIndices();
    error NotEnoughPartials();
    error WrongTotal();

    // ---------- helpers ----------
    function _election(uint256 id) private view returns (Election storage e) {
        e = elections[id];
        if (e.owner == address(0)) revert WrongState();
    }

    /// w = N - (n - 1). n is odd, so n - 1 only clears the last bit.
    function _computeW(bytes memory n, bytes memory NN) private pure returns (bytes memory) {
        bytes memory nm1 = BigMath.padLeft(n, NN.length);
        nm1[nm1.length - 1] = bytes1(uint8(nm1[nm1.length - 1]) & 0xfe);
        return BigMath.sub(NN, nm1);
    }

    function _isZero(bytes memory x) private pure returns (bool) {
        for (uint256 i = 0; i < x.length / 32; i++) {
            uint256 v;
            assembly ("memory-safe") {
                v := mload(add(add(x, 0x20), shl(5, i)))
            }
            if (v != 0) return false;
        }
        return true;
    }

    // ---------- election lifecycle ----------
    function createElection(
        bytes calldata n,
        address[] calldata eligible,
        uint8 committeeSize,
        uint8 threshold
    ) external returns (uint256 id) {
        uint256 len = n.length;
        if (len != 64 && len != 128 && len != 256) revert BadLength();
        if ((uint8(n[0]) & 0x80) == 0 || (uint8(n[len - 1]) & 0x01) == 0) revert OutOfRange();
        if (committeeSize == 0 || threshold == 0 || threshold > committeeSize) revert OutOfRange();

        bytes memory nMem = n;
        bytes memory NN = BigMath.exactSquare(nMem);

        id = ++electionCount;
        Election storage e = elections[id];
        e.owner = msg.sender;
        e.committeeSize = committeeSize;
        e.threshold = threshold;
        e.n = nMem;
        e.N = NN;
        e.w = _computeW(nMem, NN);

        bytes memory t = new bytes(2 * len);
        t[2 * len - 1] = 0x01; // encryption of 0 with r = 1
        e.tally = t;

        for (uint256 i = 0; i < eligible.length; i++) {
            e.eligible[eligible[i]] = true;
        }

        emit ElectionCreated(id, msg.sender, len * 8);
    }

    function openVoting(uint256 id) external {
        Election storage e = _election(id);
        if (msg.sender != e.owner) revert NotOwner();
        if (e.state != State.Setup) revert WrongState();
        e.state = State.Open;
    }

    function castVote(uint256 id, bytes calldata c, Proof calldata p) external {
        Election storage e = _election(id);

        // step 1
        if (e.state != State.Open) revert WrongState();
        if (!e.eligible[msg.sender]) revert NotEligible();
        if (e.voted[msg.sender]) revert AlreadyVoted();

        // steps 2-6: lengths, ranges, challenge, both branch equations
        bytes memory cMem = c;
        OrProofVerifier.verify(e.n, e.N, e.w, id, msg.sender, cMem, p);

        // step 7
        e.tally = BigMath.mulmodN(e.tally, cMem, e.N);
        e.voted[msg.sender] = true;
        e.ballotHash[msg.sender] = keccak256(cMem);
        e.ballotCount += 1;
        emit BallotCast(id, msg.sender, cMem);
    }

    function closeVoting(uint256 id) external {
        Election storage e = _election(id);
        if (msg.sender != e.owner) revert NotOwner();
        if (e.state != State.Open) revert WrongState();
        e.state = State.Closed;
        emit VotingClosed(id, e.tally);
    }

    // ---------- reveal (Phase 2) ----------
    /// Owner only, state Setup or Open. A member's index is its position + 1.
    function setCommittee(uint256 id, address[] calldata members) external {
        Election storage e = _election(id);
        if (msg.sender != e.owner) revert NotOwner();
        if (e.state != State.Setup && e.state != State.Open) revert WrongState();
        if (members.length != e.committeeSize) revert BadLength();
        if (e.committeeSize > MAX_COMMITTEE) revert OutOfRange();

        // forget a previous committee
        for (uint256 i = 0; i < e.members.length; i++) {
            delete e.memberIndex[e.members[i]];
        }
        delete e.members;

        for (uint256 i = 0; i < members.length; i++) {
            address m = members[i];
            if (m == address(0) || e.memberIndex[m] != 0) revert OutOfRange();
            e.memberIndex[m] = uint8(i + 1);
            e.members.push(m);
        }
        e.committeeSet = true;
    }

    function submitPartial(uint256 id, bytes calldata value) external {
        Election storage e = _election(id);
        if (e.state != State.Closed) revert WrongState();
        if (!e.committeeSet) revert CommitteeNotSet();
        uint8 idx = e.memberIndex[msg.sender];
        if (idx == 0) revert NotCommittee();
        if (e.submitted[idx]) revert AlreadySubmitted();
        if (value.length != e.N.length) revert BadLength();
        bytes memory v = value;
        if (_isZero(v) || !BigMath.lt(v, e.N)) revert OutOfRange();

        e.partials[idx] = v;
        e.submitted[idx] = true;
        e.partialCount += 1;
        emit PartialSubmitted(id, idx);
    }

    function finalizeTally(uint256 id, uint8[] calldata indices, uint256 total) external {
        Election storage e = _election(id);
        if (e.state != State.Closed) revert WrongState();
        if (!e.committeeSet) revert CommitteeNotSet();
        _checkIndices(e, indices);
        if (total > e.ballotCount) revert WrongTotal();

        _verifyTotal(e, indices, total);

        e.total = total;
        e.state = State.Finalized;
        emit TallyFinalized(id, total);
    }

    function _checkIndices(Election storage e, uint8[] calldata indices) private view {
        if (indices.length != e.threshold) revert BadIndices();
        for (uint256 k = 0; k < indices.length; k++) {
            uint8 i = indices[k];
            if (i < 1 || i > e.committeeSize) revert BadIndices();
            if (k > 0 && indices[k - 1] >= i) revert BadIndices(); // strictly increasing
        }
        for (uint256 k = 0; k < indices.length; k++) {
            if (!e.submitted[indices[k]]) revert NotEnoughPartials();
        }
    }

    function _factorial(uint8 n) private pure returns (uint256 f) {
        f = 1;
        for (uint256 i = 2; i <= n; i++) {
            f *= i;
        }
    }

    /// lambda_i = Delta * prod_{j != i} j / prod_{j != i} (j - i), exact, may be negative.
    function _lambda(uint8[] calldata indices, uint8 i, uint256 delta) private pure returns (int256) {
        int256 num = int256(delta);
        int256 den = 1;
        for (uint256 k = 0; k < indices.length; k++) {
            uint8 j = indices[k];
            if (j == i) continue;
            num *= int256(uint256(j));
            den *= int256(uint256(j)) - int256(uint256(i));
        }
        if (num % den != 0) revert BadIndices();
        return num / den;
    }

    function _term(Election storage e, bytes memory N, uint8 i, int256 lam) private view returns (bytes memory) {
        uint256 absLam = lam < 0 ? uint256(-lam) : uint256(lam);
        return BigMath.modexp(e.partials[i], abi.encodePacked(2 * absLam), N);
    }

    /// P = product of partial_i^(2*lambda_i) over positive lambda, Q = same over negative lambda.
    function _product(Election storage e, uint8[] calldata indices)
        private
        view
        returns (bytes memory P, bytes memory Q)
    {
        bytes memory N = e.N;
        P = new bytes(N.length);
        P[N.length - 1] = 0x01;
        Q = new bytes(N.length);
        Q[N.length - 1] = 0x01;
        uint256 delta = _factorial(e.committeeSize);
        for (uint256 k = 0; k < indices.length; k++) {
            uint8 i = indices[k];
            int256 lam = _lambda(indices, i, delta);
            bytes memory term = _term(e, N, i, lam);
            if (lam < 0) {
                Q = BigMath.mulmodN(Q, term, N);
            } else {
                P = BigMath.mulmodN(P, term, N);
            }
        }
    }

    /// Accepts only if P == Y * Q mod N with Y = 4 * Delta^2 * total * n + 1.
    function _verifyTotal(Election storage e, uint8[] calldata indices, uint256 total) private view {
        (bytes memory P, bytes memory Q) = _product(e, indices);
        uint256 delta = _factorial(e.committeeSize);
        uint256 s = 4 * delta * delta * total;
        bytes memory Y = BigMath.increment(BigMath.mulSmall(BigMath.padLeft(e.n, e.N.length), s));
        if (keccak256(P) != keccak256(BigMath.mulmodN(Y, Q, e.N))) revert WrongTotal();
    }

    // ---------- getters ----------
    function getEncryptedTally(uint256 id) external view returns (bytes memory) {
        return _election(id).tally;
    }

    function getElection(uint256 id)
        external
        view
        returns (
            address owner,
            State state,
            bytes memory n,
            uint256 ballotCount,
            uint8 committeeSize,
            uint8 threshold
        )
    {
        Election storage e = _election(id);
        return (e.owner, e.state, e.n, e.ballotCount, e.committeeSize, e.threshold);
    }

    function getResult(uint256 id) external view returns (bool finalized, uint256 total, uint8 partialCount) {
        Election storage e = _election(id);
        return (e.state == State.Finalized, e.total, e.partialCount);
    }

    /// Not in the 5.3 interface: lets the frontend show eligibility and voted status.
    function isEligible(uint256 id, address who) external view returns (bool) {
        return _election(id).eligible[who];
    }

    function hasVoted(uint256 id, address who) external view returns (bool) {
        return _election(id).voted[who];
    }
    function memberIndexOf(uint256 id, address who) external view returns (uint8) {
        return _election(id).memberIndex[who];
    }
    /// Not in the 5.3 interface: lets tests check the stored N and w.
    function getModulus(uint256 id) external view returns (bytes memory N, bytes memory w) {
        Election storage e = _election(id);
        return (e.N, e.w);
    }
}   