import { CHAIN, CONTRACT, ELECTION_ID } from "./config";
import { shortAddr } from "./format";
import { useElection } from "./useElection";
import { useWallet } from "./useWallet";
import VotePanel from "./VotePanel";
import ResultsPanel from "./ResultsPanel";
import AdminPanel, { roleText } from "./AdminPanel";

export default function App() {
  const { hasWallet, account, chainId, connect, switchNetwork, error: walletError } = useWallet();
  const { data, error,  refresh  } = useElection(account);
  const wrongChain = chainId !== undefined && chainId !== CHAIN.id;

  return (
    <main>
      <header>
        <h1>Confidential DAO Voting</h1>
        <div className="row">
          <span>{account ? shortAddr(account) : "Not connected"}</span>
          <span className="tag">
            {chainId === undefined ? "network: unknown" : wrongChain ? `chain ${chainId}` : CHAIN.name}
          </span>
          {!account && (
            <button onClick={connect} disabled={!hasWallet}>
              {hasWallet ? "Connect wallet" : "Install MetaMask"}
            </button>
          )}
        </div>
        {wrongChain && (
          <div className="warn">
            Wrong network. This app uses {CHAIN.name} (chain {CHAIN.id}).{" "}
            <button onClick={switchNetwork}>Switch network</button>
          </div>
        )}
        {walletError && <div className="warn">{walletError}</div>}
      </header>

      <section>
        <h2>Election {ELECTION_ID.toString()}</h2>
        {error && <div className="warn">{error}</div>}
        {!data && !error && <p>Loading…</p>}
        {data && (
          <dl>
            <dt>Contract</dt><dd>{shortAddr(CONTRACT)}</dd>
            <dt>State</dt><dd><b>{data.state}</b></dd>
            <dt>Ballots cast</dt><dd>{data.ballotCount.toString()}</dd>
            <dt>Key size</dt><dd>{data.keyBits} bits</dd>
            <dt>Threshold</dt><dd>{data.threshold} of {data.committeeSize}</dd>
            <dt>Your address</dt>
              <dd>{account ? shortAddr(account) : "Not connected"}</dd>
            <dt>Your role</dt><dd>{roleText(data, account)}</dd>
            <dd>
              {!account ? "connect a wallet to check"
                : data.eligible ? (data.voted ? "eligible, already voted" : "eligible, not voted yet")
                : "not eligible"}
            </dd>
          </dl>
        )}
      </section>

                  {data && <AdminPanel data={data} account={account} wrongChain={wrongChain} onDone={refresh} />}
      {data && <VotePanel data={data} account={account} wrongChain={wrongChain} onDone={refresh} />}
            {data && <ResultsPanel data={data} />}
    </main>
  );
}