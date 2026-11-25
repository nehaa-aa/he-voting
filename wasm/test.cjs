// Checks the WASM ballot against the real Rust verifier (hevote verify).
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const wasm = require("./pkg-node/he_wasm.js");

const root = path.resolve(__dirname, "..");
const hevote = path.join(process.env.CARGO_TARGET_DIR || path.join(root, "target"), "release", "hevote");
const work = path.join(root, "work", "wasm");
fs.mkdirSync(work, { recursive: true });
const voters = JSON.parse(fs.readFileSync(path.join(root, "fixtures", "voters.json"), "utf8"));

let failures = 0;
function check(name, ok) {
  console.log((ok ? "PASS " : "FAIL ") + name);
  if (!ok) failures++;
}
function throws(fn) {
  try { fn(); return false; } catch (_) { return true; }
}
function hevoteVerify(pkFile, eid, ballotFile) {
  const r = spawnSync(hevote, ["verify", "--pk", pkFile, "--election-id", eid, "--ballot", ballotFile], { encoding: "utf8" });
  return { ok: r.status === 0 && r.stdout.trim() === "valid", status: r.status, out: (r.stdout || "").trim() };
}

for (const bits of [512, 1024]) {
  const fx = JSON.parse(fs.readFileSync(path.join(root, "fixtures", `election_${bits}.json`), "utf8"));
  const pkFile = path.join(work, `public_${bits}.json`);
  fs.writeFileSync(pkFile, JSON.stringify({ keyBits: bits, n: fx.n }));
  const ballotFile = path.join(work, `ballot_${bits}.json`);
  const make = (vote) => wasm.encrypt_ballot(fx.n, fx.electionId, voters[0], vote);

  for (const vote of [0, 1]) {
    const s = make(vote);
    fs.writeFileSync(ballotFile, s);
    check(`${bits}-bit: WASM ballot (vote ${vote}) verifies with hevote verify`, hevoteVerify(pkFile, fx.electionId, ballotFile).ok);
  }

  const s = make(1);
  const parsed = JSON.parse(s);
  check(`${bits}-bit: ballot has exactly voter, electionId, c, proof`,
    JSON.stringify(Object.keys(parsed).sort()) === JSON.stringify(["c", "electionId", "proof", "voter"]));
  check(`${bits}-bit: ballot text has no vote or r field`, !/"vote"|"r"/.test(s));
  check(`${bits}-bit: two ballots for the same vote differ`, make(1) !== make(1));

  // tampered ballot (flip the last hex digit of z0)
  const t = JSON.parse(s);
  const last = t.proof.z0.slice(-1);
  t.proof.z0 = t.proof.z0.slice(0, -1) + (parseInt(last, 16) ^ 1).toString(16);
  fs.writeFileSync(ballotFile, JSON.stringify(t));
  check(`${bits}-bit: tampered ballot fails hevote verify`, !hevoteVerify(pkFile, fx.electionId, ballotFile).ok);

  // wrong election id
  fs.writeFileSync(ballotFile, s);
  check(`${bits}-bit: wrong election id fails hevote verify`, !hevoteVerify(pkFile, "2", ballotFile).ok);

  check(`${bits}-bit: vote of 2 is rejected`, throws(() => make(2)));
  check(`${bits}-bit: vote of 255 is rejected`, throws(() => make(255)));
  check(`${bits}-bit: bad voter length is rejected`, throws(() => wasm.encrypt_ballot(fx.n, fx.electionId, "0x1234", 1)));

  // timing
  const ms = [];
  for (let i = 0; i < 5; i++) {
    const t0 = performance.now();
    make(i % 2);
    ms.push(performance.now() - t0);
  }
  const sorted = [...ms].sort((a, b) => a - b);
  console.log(`TIME ${bits}-bit encrypt_ballot (Node, 5 runs): first ${ms[0].toFixed(1)} ms, min ${sorted[0].toFixed(1)}, median ${sorted[2].toFixed(1)}, max ${sorted[4].toFixed(1)}`);
}

console.log(failures === 0 ? "ALL PASSED" : `${failures} FAILED`);
process.exit(failures === 0 ? 1 - 1 : 1);