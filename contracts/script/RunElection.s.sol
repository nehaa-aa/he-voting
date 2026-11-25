// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HEVoting} from "../src/HEVoting.sol";
import {Proof} from "../src/OrProofVerifier.sol";

contract RunElection is Script {
    string constant MNEMONIC = "test test test test test test test test test test test junk";

    function run() external {
        uint256 bits = vm.envOr("BITS", uint256(1024));
        string memory json = vm.readFile(string.concat("../fixtures/election_", vm.toString(bits), ".json"));

        address[] memory voters = new address[](10);
        uint256[] memory keys = new uint256[](10);
        for (uint256 i = 0; i < 10; i++) {
            keys[i] = vm.deriveKey(MNEMONIC, uint32(i + 1));
            voters[i] = vm.parseJsonAddress(json, _ballot(i, "voter"));
            require(vm.addr(keys[i]) == voters[i], "fixture voter is not the derived Anvil account");
        }

        // owner = Anvil account 0
        uint256 ownerKey = vm.deriveKey(MNEMONIC, 0);
        vm.startBroadcast(ownerKey);
        HEVoting hv = new HEVoting();
        uint256 id = hv.createElection(vm.parseJsonBytes(json, ".n"), voters, 5, 3);
        hv.openVoting(id);
        vm.stopBroadcast();
        require(id == uint256(vm.parseJsonBytes32(json, ".electionId")), "election id differs from the fixture");

        for (uint256 i = 0; i < 10; i++) {
            _cast(hv, id, json, i, keys[i]);
        }

        vm.startBroadcast(ownerKey);
        hv.closeVoting(id);
        vm.stopBroadcast();

        bytes memory tally = hv.getEncryptedTally(id);
        require(
            keccak256(tally) == keccak256(vm.parseJsonBytes(json, ".expectedEncryptedTally")),
            "on-chain tally != expectedEncryptedTally"
        );
        (,,, uint256 count,,) = hv.getElection(id);

        vm.writeFile(
            "../fixtures/onchain_tally.json",
            string.concat('{"tally":"', vm.toString(tally), '","ballotCount":', vm.toString(count), "}")
        );
        console.log("HEVoting deployed at", address(hv));
        console.log("ballots counted", count);
    }

    function _cast(HEVoting hv, uint256 id, string memory json, uint256 i, uint256 key) private {
        bytes memory c = vm.parseJsonBytes(json, _ballot(i, "c"));
        Proof memory p = _proof(json, i);
        vm.startBroadcast(key);
        hv.castVote(id, c, p);
        vm.stopBroadcast();
    }

    function _ballot(uint256 i, string memory field) private pure returns (string memory) {
        return string.concat(".validBallots[", vm.toString(i), "].", field);
    }

    function _proof(string memory json, uint256 i) private pure returns (Proof memory p) {
        string memory b = string.concat(".validBallots[", vm.toString(i), "].proof.");
        p.a0 = vm.parseJsonBytes(json, string.concat(b, "a0"));
        p.a1 = vm.parseJsonBytes(json, string.concat(b, "a1"));
        p.z0 = vm.parseJsonBytes(json, string.concat(b, "z0"));
        p.z1 = vm.parseJsonBytes(json, string.concat(b, "z1"));
        p.e0 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, "e0"))));
        p.e1 = uint128(bytes16(vm.parseJsonBytes(json, string.concat(b, "e1"))));
    }
}