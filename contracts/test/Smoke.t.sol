// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract SmokeTest is Test {
    function test_can_read_fixture() public view {
        string memory json = vm.readFile("../fixtures/election_512.json");
        uint256 keyBits = vm.parseJsonUint(json, ".keyBits");
        assertEq(keyBits, 512);
    }
}