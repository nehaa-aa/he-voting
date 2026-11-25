// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {HEVoting} from "../src/HEVoting.sol";

contract ViewsTest is Test {
    function _n() private pure returns (bytes memory n) {
        n = new bytes(64);
        n[0] = 0x80;
        n[63] = 0x01;
    }

    function test_isEligible_and_hasVoted() public {
        HEVoting hv = new HEVoting();
        address[] memory el = new address[](1);
        el[0] = address(0xA11CE);
        uint256 id = hv.createElection(_n(), el, 5, 3);
        assertTrue(hv.isEligible(id, address(0xA11CE)));
        assertFalse(hv.isEligible(id, address(0xB0B)));
        assertFalse(hv.hasVoted(id, address(0xA11CE)));
    }

    function test_memberIndexOf() public {
        HEVoting hv = new HEVoting();
        address[] memory el = new address[](0);
        uint256 id = hv.createElection(_n(), el, 2, 2);
        address[] memory m = new address[](2);
        m[0] = address(0xC1);
        m[1] = address(0xC2);
        hv.setCommittee(id, m);
        assertEq(hv.memberIndexOf(id, address(0xC1)), 1);
        assertEq(hv.memberIndexOf(id, address(0xC2)), 2);
        assertEq(hv.memberIndexOf(id, address(0xDEAD)), 0);
    }
}