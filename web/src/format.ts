export const STATE_NAMES = ["Setup", "Open", "Closed", "Finalized"] as const;

export const shortAddr = (a?: string): string => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

/** Bit length of a fixed-width big-endian hex string: 0x + 128 hex chars = 512 bits. */
export const bitsOfN = (nHex: string): number => (nHex.length - 2) * 4;

/** uint256 election id as a 32-byte big-endian 0x hex string. */
export const toBytes32Hex = (id: bigint): string => "0x" + id.toString(16).padStart(64, "0");

/** First 16 hex characters of a 0x-prefixed ciphertext. */
export const first16 = (hex: string): string => hex.slice(2, 18);

const MESSAGES: Record<string, string> = {
  AlreadyVoted: "You have already voted in this election.",
  NotEligible: "This address is not on the voter list.",
  WrongState: "That action is not allowed in the election's current state.",
  InvalidProof: "The contract rejected the ballot proof.",
  InvalidChallenge: "The contract rejected the ballot proof.",
  BadLength: "A value has the wrong size.",
  OutOfRange: "A value is out of range.",
  NotOwner: "Only the election owner can do this.",
  NotCommittee: "This address is not a committee member.",
  AlreadySubmitted: "This member has already submitted a partial decryption.",
  CommitteeNotSet: "The committee has not been set.",
  BadIndices: "The chosen member indices are not valid.",
  NotEnoughPartials: "Not enough partial decryptions have been submitted.",
  WrongTotal: "The submitted partials do not match that total.",
};

/** Contract error name from a viem or wallet error, if there is one. */
export function errorName(err: unknown): string | undefined {
  let e: any = err;
  for (let depth = 0; e && depth < 8; depth++, e = e.cause) {
    const name: string | undefined = e.data?.errorName;
    if (name) return name;
  }
  const text = String((err as any)?.shortMessage ?? (err as any)?.message ?? "");
  return Object.keys(MESSAGES).find((n) => text.includes(n));
}

/** Turns a wallet or contract error into a readable message. Never includes the vote or a key. */
export function contractErrorMessage(err: unknown): string {
  let e: any = err;
  for (let depth = 0; e && depth < 8; depth++, e = e.cause) {
    if (e.code === 4001 || e.name === "UserRejectedRequestError") {
      return "You rejected the request in your wallet.";
    }
  }
  const name = errorName(err);
  if (name && MESSAGES[name]) return MESSAGES[name];
  if (err instanceof Error && err.message.startsWith("UI:")) return err.message.slice(3).trim();
  return "The transaction failed. Check the wallet and the network, then try again.";
}