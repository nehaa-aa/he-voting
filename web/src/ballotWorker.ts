import init, { encrypt_ballot, partial_decrypt_share } from "he-wasm";

type Req =
  | { kind: "ballot"; n: string; eid: string; voter: string; vote: number }
  | { kind: "partial"; n: string; share: string; tally: string };
let ready: Promise<unknown> | undefined;

self.onmessage = async (ev: MessageEvent<Req>) => {
  try {
    ready ??= init();
    await ready;
    const m = ev.data;
    const t0 = performance.now();
    const json =
      m.kind === "ballot"
        ? encrypt_ballot(m.n, m.eid, m.voter, m.vote)
        : partial_decrypt_share(m.n, m.share, m.tally);
    self.postMessage({ ok: true, json, ms: Math.round(performance.now() - t0) });
  } catch (e) {
    self.postMessage({ ok: false, error: e instanceof Error ? e.message : "Operation failed" });
  }
};