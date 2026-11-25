// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BigMath} from "./BigMath.sol";
import {OrProofVerifier, Proof} from "./OrProofVerifier.sol";
import {OrProofVerifier, Proof, BadLength, OutOfRange} from "./OrProofVerifier.sol";
contract HEVoting {
    enum State { Setup, Open, Closed }

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
    }

    mapping(uint256 => Election) private elections;
    uint256 public electionCount;

    event ElectionCreated(uint256 indexed id, address owner, uint256 keyBits);
    event BallotCast(uint256 indexed id, address indexed voter, bytes c);
    event VotingClosed(uint256 indexed id, bytes encryptedTally);

    error NotOwner();
    error WrongState();
    error NotEligible();
    error AlreadyVoted();

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

    /// Not in the 5.3 interface: lets tests check the stored N and w.
    function getModulus(uint256 id) external view returns (bytes memory N, bytes memory w) {
        Election storage e = _election(id);
        return (e.N, e.w);
    }
}