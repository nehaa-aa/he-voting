export type Ballot = {
  voter: string;
  electionId: string;
  c: string;
  proof: { a0: string; a1: string; z0: string; z1: string; e0: string; e1: string };
};

function runWorker(msg: object): Promise<{ json: string; ms: number }> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL("./ballotWorker.ts", import.meta.url), { type: "module" });
    worker.onmessage = (ev: MessageEvent) => {
      worker.terminate();
      if (ev.data.ok) resolve({ json: ev.data.json, ms: ev.data.ms });
      else reject(new Error("UI: " + ev.data.error));
    };
    worker.onerror = () => {
      worker.terminate();
      reject(new Error("UI: the browser crypto failed to run"));
    };
    worker.postMessage(msg);
  });
}

/** Encrypts and proves a vote in a Web Worker. */
export async function encryptBallot(
  n: string, eid: string, voter: string, vote: 0 | 1,
): Promise<{ ballot: Ballot; ms: number }> {
  const r = await runWorker({ kind: "ballot", n, eid, voter, vote });
  return { ballot: JSON.parse(r.json) as Ballot, ms: r.ms };
}

/** A committee member's partial decryption. The share file text stays in this tab and is never sent anywhere. */
export async function partialDecrypt(
  n: string, shareJson: string, tallyHex: string,
): Promise<{ partial: { index: number; value: string }; ms: number }> {
  const r = await runWorker({ kind: "partial", n, share: shareJson, tally: tallyHex });
  return { partial: JSON.parse(r.json), ms: r.ms };
}