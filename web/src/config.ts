import { defineChain } from "viem";

export const RPC_URL: string = import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:8545";

export const CHAIN = defineChain({
  id: 31337,
  name: "Anvil (local)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const CONTRACT = import.meta.env.VITE_CONTRACT_ADDRESS as `0x${string}` | undefined;
export const ELECTION_ID = BigInt(import.meta.env.VITE_ELECTION_ID ?? "1");