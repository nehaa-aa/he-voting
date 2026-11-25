import { useCallback, useEffect, useState } from "react";
import { createPublicClient, http } from "viem";
import { abi } from "./abi";
import { CHAIN, CONTRACT, ELECTION_ID, RPC_URL } from "./config";
import { bitsOfN, STATE_NAMES } from "./format";

export const client = createPublicClient({ chain: CHAIN, transport: http(RPC_URL) });

export type ElectionView = {
  owner: string;
  state: (typeof STATE_NAMES)[number];
  ballotCount: bigint;
  nHex: string;
  keyBits: number;
  committeeSize: number;
  threshold: number;
  finalized: boolean;
  total: bigint;
  partialCount: number;
  eligible?: boolean;
  voted?: boolean;
  memberIndex?: number;
};

export function useElection(account?: `0x${string}`) {
  const [data, setData] = useState<ElectionView>();
  const [error, setError] = useState<string>();

  const refresh = useCallback(async () => {
    if (!CONTRACT) {
      setError("VITE_CONTRACT_ADDRESS is not set. Run scripts/deploy_open.sh.");
      return;
    }
    try {
      const [owner, state, n, ballotCount, committeeSize, threshold] = await client.readContract({
        address: CONTRACT, abi, functionName: "getElection", args: [ELECTION_ID],
      });
      const [finalized, total, partialCount] = await client.readContract({
        address: CONTRACT, abi, functionName: "getResult", args: [ELECTION_ID],
      });
      let eligible: boolean | undefined;
      let voted: boolean | undefined;
      let memberIndex: number | undefined;
      if (account) {
        [eligible, voted, memberIndex] = await Promise.all([
          client.readContract({ address: CONTRACT, abi, functionName: "isEligible", args: [ELECTION_ID, account] }),
          client.readContract({ address: CONTRACT, abi, functionName: "hasVoted", args: [ELECTION_ID, account] }),
          client.readContract({ address: CONTRACT, abi, functionName: "memberIndexOf", args: [ELECTION_ID, account] }),
        ]);
      }
      setData({
        owner, state: STATE_NAMES[state] ?? "Setup", ballotCount, nHex: n, keyBits: bitsOfN(n),
        committeeSize, threshold, finalized, total, partialCount, eligible, voted, memberIndex,
      });
      setError(undefined);
    } catch {
      setError("Could not read the election. Is Anvil running and is the contract address current?");
    }
  }, [account]);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 3000);
    return () => clearInterval(t);
  }, [refresh]);

  return { data, error, refresh };
}