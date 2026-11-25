// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {HEVoting} from "../src/HEVoting.sol";

/// Deploys, creates election 1 from the fixture key, sets the committee and opens voting.
/// No votes are cast, so the browser (Step 8) and the CLI can vote afterwards.
contract DeployOpen is Script {
    string constant MNEMONIC = "test test test test test test test test test test test junk";

    function run() external {
        uint256 bits = vm.envOr("BITS", uint256(1024));
        string memory json = vm.readFile(string.concat("../fixtures/election_", vm.toString(bits), ".json"));

        address[] memory voters = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            voters[i] = vm.parseJsonAddress(
                json, string.concat(".validBallots[", vm.toString(i), "].voter")
            );
        }

        vm.startBroadcast(vm.deriveKey(MNEMONIC, 0));
        HEVoting hv = new HEVoting();
        uint256 id = hv.createElection(vm.parseJsonBytes(json, ".n"), voters, 5, 3);
        hv.setCommittee(id, vm.parseJsonAddressArray(vm.readFile("../fixtures/committee.json"), "$"));
        if (vm.envOr("OPEN", true)) hv.openVoting(id);
        vm.stopBroadcast();

        vm.writeFile("../fixtures/onchain_address.txt", vm.toString(address(hv)));
        console.log("Open election", id, "at", address(hv));
    }
}