import { createWalletClient, custom } from "viem";
import { abi } from "./abi";
import { CHAIN, CONTRACT } from "./config";
import { client } from "./useElection";

/** Sends a contract transaction through the wallet and waits for it. The wallet signs; no key enters the page. */
export async function sendTx(account: `0x${string}`, functionName: string, args: unknown[]): Promise<string> {
  if (!CONTRACT) throw new Error("UI: contract address is not configured");
  const wallet = createWalletClient({
    chain: CHAIN,
    transport: custom((window as unknown as { ethereum: any }).ethereum),
  });
  const hash = await wallet.writeContract({ account, address: CONTRACT, abi, functionName, args } as any);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("UI: the transaction reverted");
  return hash;
}
