import { useEffect, useState } from "react";
import { abi } from "./abi";
import { sendTx } from "./chain";
import { CONTRACT, ELECTION_ID } from "./config";
import { partialDecrypt } from "./encrypt";
import { contractErrorMessage, errorName } from "./format";
import { client, type ElectionView } from "./useElection";

export function roleText(data: ElectionView, account?: string): string {
  const roles: string[] = [];
  if (account && data.owner.toLowerCase() === account.toLowerCase()) roles.push("owner");
  if (data.eligible) roles.push("voter");
  if (data.memberIndex) roles.push(`committee member ${data.memberIndex}`);
  return roles.length ? roles.join(", ") : "none";
}

async function submittedIndices(): Promise<number[]> {
  if (!CONTRACT) return [];
  const logs = await client.getContractEvents({
    address: CONTRACT, abi, eventName: "PartialSubmitted", args: { id: ELECTION_ID }, fromBlock: 0n,
  });
  const idx = logs.map((l) => Number((l.args as any).memberIndex)).filter((x) => x > 0);
  return [...new Set(idx)].sort((a, b) => a - b);
}

function shareIndexOf(text: string): number | undefined {
  try {
    const v = JSON.parse(text);
    return typeof v.index === "number" ? v.index : undefined;
  } catch {
    return undefined;
  }
}

export default function AdminPanel(props: {
  data: ElectionView;
  account?: `0x${string}`;
  wrongChain: boolean;
  onDone: () => void;
}) {
  const { data, account, wrongChain, onDone } = props;
  const [busy, setBusy] = useState<string>();
  const [error, setError] = useState<string>();
  const [tx, setTx] = useState<string>();
  const [note, setNote] = useState<string>();
  const [shareText, setShareText] = useState<string>();
  const [fileKey, setFileKey] = useState(0);
  const [submitted, setSubmitted] = useState<number[]>([]);

  useEffect(() => {
    if (data.state === "Closed") submittedIndices().then(setSubmitted).catch(() => {});
  }, [data.state, data.partialCount]);

  if (!account) return null;
  const isOwner = data.owner.toLowerCase() === account.toLowerCase();
  const member = data.memberIndex ?? 0;
  const mySubmitted = member > 0 && submitted.includes(member);
  const disabled = busy !== undefined || wrongChain;

  async function run(first: string, fn: () => Promise<string | void>) {
    setError(undefined); setTx(undefined); setNote(undefined); setBusy(first);
    try {
      const hash = await fn();
      if (hash) setTx(hash);
      onDone();
    } catch (e) {
      setError(contractErrorMessage(e));
    } finally {
      setBusy(undefined);
    }
  }

  const ownerAction = (fn: "openVoting" | "closeVoting") =>
    run("Waiting for wallet…", () => sendTx(account, fn, [ELECTION_ID]));

  const submitMyPartial = () =>
    run("Reading the encrypted tally…", async () => {
      if (!CONTRACT || !shareText) throw new Error("UI: choose your share file first");
      const idx = shareIndexOf(shareText);
      if (idx === undefined) throw new Error("UI: that file is not a key share file");
      if (idx !== member) throw new Error(`UI: this share file is for member ${idx}, but your wallet is committee member ${member}`);
      const tally = await client.readContract({ address: CONTRACT, abi, functionName: "getEncryptedTally", args: [ELECTION_ID] });
      setBusy("Computing your partial decryption in the browser…");
      const { partial, ms } = await partialDecrypt(data.nHex, shareText, tally);
      setNote(`Partial decryption computed in ${ms} ms. Your share never left this tab.`);
      setBusy("Waiting for wallet…");
      const hash = await sendTx(account, "submitPartial", [ELECTION_ID, partial.value]);
      setShareText(undefined);
      setFileKey((k) => k + 1);
      return hash;
    });

  const finalize = () =>
    run("Reading the submitted partials…", async () => {
      if (!CONTRACT) throw new Error("UI: contract address is not configured");
      const all = await submittedIndices();
      if (all.length < data.threshold) throw new Error("UI: not enough partials submitted yet");
      const indices = all.slice(0, data.threshold);
      setBusy("Checking each possible total against the contract…");
      let found: number | undefined;
      for (let t = 0; t <= Number(data.ballotCount); t++) {
        try {
          await client.simulateContract({
            account, address: CONTRACT, abi, functionName: "finalizeTally", args: [ELECTION_ID, indices, BigInt(t)],
          });
          found = t;
          break;
        } catch (e) {
          if (errorName(e) !== "WrongTotal") throw e; // any other error is a real problem
        }
      }
      if (found === undefined) throw new Error("UI: no total matches the submitted partials. One of them may be wrong.");
      setNote(`The contract accepts total ${found} for members ${indices.join(", ")}.`);
      setBusy("Waiting for wallet…");
      return sendTx(account, "finalizeTally", [ELECTION_ID, indices, BigInt(found)]);
    });

  return (
    <section>
      <h2>Admin and committee</h2>

      {isOwner && (
        <div>
          <h3>Owner</h3>
          {data.state === "Setup" && <button disabled={disabled} onClick={() => ownerAction("openVoting")}>Open voting</button>}
          {data.state === "Open" && <button disabled={disabled} onClick={() => ownerAction("closeVoting")}>Close voting ({data.ballotCount.toString()} ballots)</button>}
          {(data.state === "Closed" || data.state === "Finalized") && <p className="muted">Voting is closed. Nothing left for the owner to do.</p>}
        </div>
      )}

      {member > 0 && (
        <div>
          <h3>Committee member {member}</h3>
          {data.state !== "Closed" && <p className="muted">Waiting for voting to close.</p>}
          {data.state === "Closed" && mySubmitted && <p>You have submitted your partial decryption.</p>}
          {data.state === "Closed" && !mySubmitted && (
            <div>
              <p>Choose your key share file. It is read in this tab only and is not uploaded.</p>
              <div className="row">
                <input
                  key={fileKey} type="file" accept="application/json,.json" disabled={disabled}
                  onChange={async (e) => { const f = e.target.files?.[0]; setShareText(f ? await f.text() : undefined); }}
                />
                <button disabled={disabled || !shareText} onClick={submitMyPartial}>Decrypt my part and submit</button>
              </div>
            </div>
          )}
        </div>
      )}

      {data.state === "Closed" && (
        <div>
          <h3>Finalize</h3>
            <p>
            {data.partialCount >= data.threshold
              ? "Enough committee members have signed. The tally can now be revealed."
              : `Locked until ${data.threshold} of ${data.committeeSize} committee members have signed (${data.partialCount} so far).`}
          </p>
          <button disabled={disabled || data.partialCount < data.threshold} onClick={finalize}>Finalize tally</button>
        </div>
      )}

      {!isOwner && member === 0 && data.state !== "Closed" && (
        <p className="muted">This account has no admin or committee actions right now.</p>
      )}

      {busy && <p>{busy}</p>}
      {note && <p className="muted">{note}</p>}
      {tx && <p>Transaction: <code>{tx}</code></p>}
      {error && <div className="warn">{error}</div>}
    </section>
  );
}