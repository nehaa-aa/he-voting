// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

contract ModexpSpikeTest is Test {
    function _modexp(bytes memory b, bytes memory e, bytes memory m)
        internal view returns (bytes memory out)
    {
        bytes memory input = abi.encodePacked(b.length, e.length, m.length, b, e, m);
        out = new bytes(m.length);
        bool ok;
        assembly {
            ok := staticcall(gas(), 0x05, add(input, 0x20), mload(input), add(out, 0x20), mload(m))
        }
        require(ok, "modexp failed");
    }

    function _path(uint256 i, string memory field) internal pure returns (string memory) {
        return string.concat(".bigMathVectors.modexp[", vm.toString(i), "].", field);
    }

    function _check(string memory file) internal {
        string memory json = vm.readFile(file);
        for (uint256 i = 0; i < 8; i++) { // the demo writes 8 modexp vectors
            bytes memory base = vm.parseJsonBytes(json, _path(i, "base"));
            bytes memory exp  = vm.parseJsonBytes(json, _path(i, "exp"));
            bytes memory mod  = vm.parseJsonBytes(json, _path(i, "mod"));
            bytes memory want = vm.parseJsonBytes(json, _path(i, "out"));

            uint256 g = gasleft();
            bytes memory got = _modexp(base, exp, mod);
            g -= gasleft();

            emit log_named_uint(string.concat("vector ", vm.toString(i), " gas"), g);
            assertEq(got, want, string.concat("vector ", vm.toString(i)));
        }
    }

    function test_modexp_vectors_512() public { _check("../fixtures/election_512.json"); }
    function test_modexp_vectors_1024() public { _check("../fixtures/election_1024.json"); }
}