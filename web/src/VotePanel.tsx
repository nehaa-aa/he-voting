import { useEffect, useState } from "react";
import { createWalletClient, custom, type Hex } from "viem";
import { abi } from "./abi";
import { CHAIN, CONTRACT, ELECTION_ID } from "./config";
import { encryptBallot } from "./encrypt";
import { contractErrorMessage, first16, toBytes32Hex } from "./format";
import { client, type ElectionView } from "./useElection";

type Status = "idle" | "encrypting" | "wallet" | "confirming" | "done" | "error";

const LABEL: Record<Status, string> = {
  idle: "",
  encrypting: "Encrypting and proving in your browser…",
  wallet: "Waiting for your wallet…",
  confirming: "Confirming on the chain…",
  done: "Your vote has been recorded.",
  error: "",
};

export default function VotePanel(props: {
  data: ElectionView;
  account?: `0x${string}`;
  wrongChain: boolean;
  onDone: () => void;
}) {
  const { data, account, wrongChain, onDone } = props;
  const [choice, setChoice] = useState<0 | 1>();
  const [status, setStatus] = useState<Status>("idle");
  const [message, setMessage] = useState<string>();
  const [tx, setTx] = useState<string>();
  const [ctPrefix, setCtPrefix] = useState<string>();
  const [ms, setMs] = useState<number>();

  // A different wallet account must never see the previous account's ballot details.
  useEffect(() => {
    setChoice(undefined); setStatus("idle"); setMessage(undefined);
    setTx(undefined); setCtPrefix(undefined); setMs(undefined);
  }, [account]);

  if (!account) return <section><h2>Vote</h2><p className="muted">Connect a wallet to vote.</p></section>;
  if (!data.eligible) return <section><h2>Vote</h2><p className="muted">This address is not on the voter list.</p></section>;
  if (data.state !== "Open") {
    return <section><h2>Vote</h2><p className="muted">Voting is not open yet or has already closed.</p></section>;
  }

  const busy = status === "encrypting" || status === "wallet" || status === "confirming";

  async function submit() {
    if (choice === undefined || !account || !CONTRACT) return;
    const vote = choice;
    setChoice(undefined); // do not keep the plaintext vote in state longer than needed
    setMessage(undefined); setTx(undefined); setCtPrefix(undefined);
    try {
      setStatus("encrypting");
      const { ballot, ms } = await encryptBallot(data.nHex, toBytes32Hex(ELECTION_ID), account, vote as 0 | 1);
      setMs(ms);
      setCtPrefix(first16(ballot.c));

      setStatus("wallet");
      const wallet = createWalletClient({
        chain: CHAIN,
        transport: custom((window as unknown as { ethereum: any }).ethereum),
      });
      const p = ballot.proof;
      const hash = await wallet.writeContract({
        account, address: CONTRACT, abi, functionName: "castVote",
        args: [ELECTION_ID, ballot.c as Hex, {
          a0: p.a0 as Hex, a1: p.a1 as Hex, z0: p.z0 as Hex, z1: p.z1 as Hex,
          e0: BigInt(p.e0), e1: BigInt(p.e1),
        }],
      });
      setTx(hash);

      setStatus("confirming");
      const receipt = await client.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("reverted");
      setStatus("done");
      onDone();
    } catch (err) {
      setStatus("error");
      setMessage(contractErrorMessage(err));
    }
  }

  return (
    <section>
      <h2>Vote</h2>
      {data.voted && status === "idle" && (
        <div className="warn">You have already voted. A second attempt will be rejected by the contract.</div>
      )}
      <div className="choices">
        <label className="choice">
          <input type="radio" name="c" checked={choice === 1} disabled={busy || wrongChain} onChange={() => setChoice(1)} />
          Yes
        </label>
        <label className="choice">
          <input type="radio" name="c" checked={choice === 0} disabled={busy || wrongChain} onChange={() => setChoice(0)} />
          No
        </label>
        <button onClick={submit} disabled={choice === undefined || busy || wrongChain}>Encrypt and submit</button>
      </div>
      <p className="muted">Your vote is encrypted on this device before it is sent.</p>
      {LABEL[status] && <p>{LABEL[status]}</p>}
      {ms !== undefined && <p className="muted">Encrypting and proving took {ms} ms.</p>}
      {ctPrefix && <p>Ciphertext begins <code>{ctPrefix}</code></p>}
      {tx && <p>Transaction <code>{tx}</code></p>}
      {status === "error" && message && <div className="err">{message}</div>}
    </section>
  );
}