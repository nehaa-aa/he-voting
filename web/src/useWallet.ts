import { useCallback, useEffect, useState } from "react";
import { CHAIN, RPC_URL } from "./config";

type Eth = {
  request(args: { method: string; params?: unknown }): Promise<any>;
  on?(event: string, handler: (...a: any[]) => void): void;
  removeListener?(event: string, handler: (...a: any[]) => void): void;
};
const getEth = (): Eth | undefined => (window as unknown as { ethereum?: Eth }).ethereum;

export function useWallet() {
  const [account, setAccount] = useState<`0x${string}` | undefined>();
  const [chainId, setChainId] = useState<number | undefined>();
  const [error, setError] = useState<string | undefined>();
  const hasWallet = !!getEth();

  useEffect(() => {
    const eth = getEth();
    if (!eth) return;
    eth.request({ method: "eth_accounts" }).then((a) => setAccount(a[0])).catch(() => {});
    eth.request({ method: "eth_chainId" }).then((c) => setChainId(parseInt(c, 16))).catch(() => {});
    const onAccounts = (a: string[]) => setAccount(a[0] as `0x${string}` | undefined);
    const onChain = (c: string) => setChainId(parseInt(c, 16));
    eth.on?.("accountsChanged", onAccounts);
    eth.on?.("chainChanged", onChain);
    return () => {
      eth.removeListener?.("accountsChanged", onAccounts);
      eth.removeListener?.("chainChanged", onChain);
    };
  }, []);

  const connect = useCallback(async () => {
    const eth = getEth();
    if (!eth) return setError("No wallet found. Install MetaMask.");
    try {
      const a = await eth.request({ method: "eth_requestAccounts" });
      setAccount(a[0]);
      setError(undefined);
    } catch {
      setError("Wallet connection was rejected.");
    }
  }, []);

  const switchNetwork = useCallback(async () => {
    const eth = getEth();
    if (!eth) return;
    const hexId = "0x" + CHAIN.id.toString(16);
    try {
      await eth.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] });
    } catch (err: any) {
      // 4902 = chain unknown to the wallet: add it, which also switches to it
      if (err?.code === 4902 || err?.code === -32603) {
        try {
          await eth.request({
            method: "wallet_addEthereumChain",
            params: [{ chainId: hexId, chainName: CHAIN.name, nativeCurrency: CHAIN.nativeCurrency, rpcUrls: [RPC_URL] }],
          });
        } catch {
          setError("Could not add the network to the wallet.");
        }
      } else {
        setError("Could not switch network.");
      }
    }
  }, []);

  return { hasWallet, account, chainId, connect, switchNetwork, error };
}