import AdminPanel, { roleText } from "./AdminPanel";
import ResultsPanel from "./ResultsPanel";
import VotePanel from "./VotePanel";
import { CHAIN, CONTRACT, ELECTION_ID } from "./config";
import { shortAddr, STATE_NAMES } from "./format";
import { useElection, type ElectionView } from "./useElection";
import { useWallet } from "./useWallet";

const STAGE_LABELS = ["Setup", "Voting open", "Voting closed", "Result revealed"];

function voterStatus(data: ElectionView, account?: string): { text: string; tone: string } {
  if (!account) return { text: "Connect a wallet to check your eligibility.", tone: "idle" };
  if (!data.eligible) return { text: "You are not eligible to vote.", tone: "no" };
  return data.voted
    ? { text: "You are eligible to vote and have already voted.", tone: "done" }
    : { text: "You are eligible to vote and have not voted yet.", tone: "ok" };
}

export default function App() {
  const { hasWallet, account, chainId, connect, switchNetwork, error: walletError } = useWallet();
  const { data, error, refresh } = useElection(account);
  const wrongChain = chainId !== undefined && chainId !== CHAIN.id;
  const stage = data ? STATE_NAMES.indexOf(data.state) : -1;

  let role = "";
  if (data) {
    const r = roleText(data, account);
    role = r === "none" ? "No role in this election" : r.charAt(0).toUpperCase() + r.slice(1);
  }

  return (
    <main>
      <div className="top">
        <div>
          <h1>Confidential DAO Voting</h1>
          <p>Votes stay encrypted on-chain. Only the final total is revealed.</p>
        </div>
        <div className="wallet">
          {account && <span className="addr">{shortAddr(account)}</span>}
          <span className={wrongChain ? "tag bad" : "tag"}>
            {chainId === undefined ? "Network unknown" : wrongChain ? `Chain ${chainId}` : CHAIN.name}
          </span>
          {!account && (
            <button onClick={connect} disabled={!hasWallet}>
              {hasWallet ? "Connect wallet" : "Install MetaMask"}
            </button>
          )}
        </div>
      </div>

      {wrongChain && (
        <div className="warn" style={{ marginTop: "1rem" }}>
          Your wallet is on the wrong network. This app uses {CHAIN.name} (chain {CHAIN.id}).{" "}
          <button onClick={switchNetwork}>Switch network</button>
        </div>
      )}
      {walletError && <div className="err" style={{ marginTop: "1rem" }}>{walletError}</div>}
      {error && <div className="err" style={{ marginTop: "1rem" }}>{error}</div>}

      <ol className="stages">
        {STAGE_LABELS.map((label, i) => (
          <li key={label} className={i < stage ? "done" : i === stage ? "now" : ""}>{label}</li>
        ))}
      </ol>

      {data && (
        <>
          <dl className="facts">
            <div><dt>Election</dt><dd>{ELECTION_ID.toString()}</dd></div>
            <div><dt>Ballots cast</dt><dd>{data.ballotCount.toString()}</dd></div>
            <div><dt>Key size</dt><dd>{data.keyBits} bits</dd></div>
            <div><dt>Signatures needed</dt><dd>{data.threshold} of {data.committeeSize}</dd></div>
            <div><dt>Contract</dt><dd>{shortAddr(CONTRACT)}</dd></div>
          </dl>

          <section>
            <h2>You</h2>
            <dl className="rows">
              <dt>Wallet</dt><dd>{account ? shortAddr(account) : "Not connected"}</dd>
              <dt>Role</dt><dd>{role}</dd>
                            <dt>Voting status</dt>
              <dd>
                <span className={`status ${voterStatus(data, account).tone}`}>
                  {voterStatus(data, account).text}
                </span>
              </dd>
            </dl>
          </section>

          <AdminPanel data={data} account={account} wrongChain={wrongChain} onDone={refresh} />
          <VotePanel data={data} account={account} wrongChain={wrongChain} onDone={refresh} />
          <ResultsPanel data={data} />
        </>
      )}
      {!data && !error && <p className="muted">Loading election…</p>}
    </main>
  );
}