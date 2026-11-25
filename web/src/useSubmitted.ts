import { useEffect, useState } from "react";
import { abi } from "./abi";
import { CONTRACT, ELECTION_ID } from "./config";
import { client } from "./useElection";

export async function submittedIndices(): Promise<number[]> {
  if (!CONTRACT) return [];
  const logs = await client.getContractEvents({
    address: CONTRACT, abi, eventName: "PartialSubmitted", args: { id: ELECTION_ID }, fromBlock: 0n,
  });
  const idx = logs.map((l) => Number((l.args as any).memberIndex)).filter((x) => x > 0);
  return [...new Set(idx)].sort((a, b) => a - b);
}

/** Member indices that have submitted a partial decryption. */
export function useSubmitted(state: string, partialCount: number): number[] {
  const [signed, setSigned] = useState<number[]>([]);
  useEffect(() => {
    if (state === "Closed" || state === "Finalized") submittedIndices().then(setSigned).catch(() => {});
  }, [state, partialCount]);
  return signed;
}