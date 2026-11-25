import type { ElectionView } from "./useElection";
import { useSubmitted } from "./useSubmitted";

export default function ResultsPanel({ data }: { data: ElectionView }) {
  const signed = useSubmitted(data.state, data.partialCount);
  const finalized = data.state === "Finalized";
  const yes = Number(data.total);
  const no = Number(data.ballotCount - data.total);
  const all = Math.max(yes + no, 1);

  return (
    <section>
      <h2>Results</h2>
      {finalized ? (
        <>
          <div className="tally">
            <div className="figure"><b>{yes}</b><span>Yes</span></div>
            <div className="figure"><b>{no}</b><span>No</span></div>
          </div>
          <div className="bar" aria-hidden="true">
            <i className="yes" style={{ width: `${(yes / all) * 100}%` }} />
            <i className="no" style={{ width: `${(no / all) * 100}%` }} />
          </div>
          <p className="muted">{data.ballotCount.toString()} ballots counted.</p>
        </>
      ) : (
        <div className="warn">
          <b>Result locked.</b> The count is revealed only after {data.threshold} of {data.committeeSize} committee
          members sign with their own key share. Until then, the chain holds only the encrypted tally.
        </div>
      )}

      <h3>Committee signatures ({data.partialCount} of {data.threshold} signed)</h3>
      <div className="chips">
        {Array.from({ length: data.committeeSize }, (_, i) => i + 1).map((i) => (
          <span key={i} className={signed.includes(i) ? "chip done" : "chip"}>
            Member {i}: {signed.includes(i) ? "signed" : data.state === "Open" || data.state === "Setup" ? "waiting for voting to close" : "not yet"}
          </span>
        ))}
      </div>
    </section>
  );
}