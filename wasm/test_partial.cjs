// WASM partial_decrypt_share must equal `hevote partial-decrypt`, and combine of the WASM partials must give 6.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const wasm = require("./pkg-node/he_wasm.js");

const root = path.resolve(__dirname, "..");
const hevote = path.join(process.env.CARGO_TARGET_DIR || path.join(root, "target"), "release", "hevote");
const work = path.join(root, "work", "wasm-partial");
fs.mkdirSync(work, { recursive: true });
const run = (args) => spawnSync(hevote, args, { encoding: "utf8", cwd: root });
const throws = (fn) => { try { fn(); return false; } catch (_) { return true; } };
let failures = 0;
const check = (name, ok) => { console.log((ok ? "PASS " : "FAIL ") + name); if (!ok) failures++; };

for (const bits of [512, 1024]) {
  const fx = JSON.parse(fs.readFileSync(path.join(root, "fixtures", `election_${bits}.json`), "utf8"));
  const otherN = JSON.parse(fs.readFileSync(path.join(root, "fixtures", `election_${bits === 512 ? 1024 : 512}.json`), "utf8")).n;
  const keys = path.join(work, `keys_${bits}`);
  check(`${bits}: keygen --cached`, run(["keygen", "--bits", String(bits), "--members", "5", "--threshold", "3", "--out", keys, "--cached"]).status === 0);
  const tallyFile = path.join(work, `tally_${bits}.json`);
  fs.writeFileSync(tallyFile, JSON.stringify({ tally: fx.expectedEncryptedTally, ballotCount: 10 }));

  const files = [];
  for (const i of [1, 2, 5]) {
    const share = fs.readFileSync(path.join(keys, `share_${i}.json`), "utf8");
    const p = JSON.parse(wasm.partial_decrypt_share(fx.n, share, fx.expectedEncryptedTally));
    const wf = path.join(work, `wasm_partial_${bits}_${i}.json`);
    fs.writeFileSync(wf, JSON.stringify(p));
    files.push(wf);
    const cf = path.join(work, `cli_partial_${bits}_${i}.json`);
    run(["partial-decrypt", "--pk", path.join(keys, "public.json"), "--share", path.join(keys, `share_${i}.json`), "--tally", tallyFile, "--out", cf]);
    const c = JSON.parse(fs.readFileSync(cf, "utf8"));
    check(`${bits}: member ${i} WASM partial equals CLI partial`, c.index === p.index && c.value === p.value);
  }
  const out = run(["combine", "--pk", path.join(keys, "public.json"), "--partials", ...files, "--members", "5", "--threshold", "3"]);
  check(`${bits}: combine of WASM partials prints 6`, out.stdout.trim() === "6");

  const share1 = fs.readFileSync(path.join(keys, "share_1.json"), "utf8");
  check(`${bits}: share for a different key is rejected`, throws(() => wasm.partial_decrypt_share(otherN, share1, fx.expectedEncryptedTally)));
  check(`${bits}: zero tally is rejected`, throws(() => wasm.partial_decrypt_share(fx.n, share1, "0x" + "00".repeat(bits / 4))));
  check(`${bits}: broken share file is rejected`, throws(() => wasm.partial_decrypt_share(fx.n, "{", fx.expectedEncryptedTally)));
}
console.log(failures === 0 ? "ALL PASSED" : `${failures} FAILED`);
process.exit(failures === 0 ? 0 : 1);