import type { ElectionView } from "./useElection";
import { useSubmitted } from "./useSubmitted";

export default function ResultsPanel({ data }: { data: ElectionView }) {
  const signed = useSubmitted(data.state, data.partialCount);
  const finalized = data.state === "Finalized";

  return (
    <section>
      <h2>Results</h2>
      {finalized ? (
        <dl>
          <dt>Yes</dt><dd><b>{data.total.toString()}</b></dd>
          <dt>No</dt><dd><b>{(data.ballotCount - data.total).toString()}</b></dd>
          <dt>Total ballots</dt><dd>{data.ballotCount.toString()}</dd>
        </dl>
      ) : (
        <div className="warn">
          <b>Result locked.</b> The count is revealed only after {data.threshold} of {data.committeeSize} committee
          members sign with their own key share. Until then, the chain holds only the encrypted tally.
        </div>
      )}

      <h3>Committee signatures ({data.partialCount} of {data.threshold} needed)</h3>
      <div className="row">
        {Array.from({ length: data.committeeSize }, (_, i) => i + 1).map((i) => (
          <span key={i} className={signed.includes(i) ? "chip done" : "chip"}>
            Member {i}: {signed.includes(i) ? "signed ✓" : data.state === "Open" || data.state === "Setup" ? "waiting for close" : "pending"}
          </span>
        ))}
      </div>
    </section>
  );
}