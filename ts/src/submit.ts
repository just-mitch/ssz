// Run a verify_el_state_root call against the BeaconElProof contract on the
// Aztec local network.
//
// The contract has no public functions and no initializer, so it does not need
// to be "deployed" on-chain. We compute its deterministic address from the
// artifact + zero salt and register it locally with the PXE — that's enough to
// simulate, and enough to send a tx (the first tx implicitly creates it).
//
// Usage:
//   yarn submit                        # default proof file, simulate
//   yarn submit proof-14190879.json    # specific proof
//   MODE=send yarn submit              # broadcast tx (real client-side proof)
//
// Env:
//   AZTEC_NODE_URL    default http://localhost:8080
//   MODE              "simulate" (default) or "send"
//   PXE_PROVER        "wasm" (default for send), "native" (needs BB_BINARY_PATH),
//                     or "none". simulate ignores this and runs unproven.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { getInitialTestAccountsData } from "@aztec/accounts/testing";
import { BackendType, Barretenberg } from "@aztec/bb.js";
import { Fr } from "@aztec/aztec.js/fields";
import { createAztecNodeClient } from "@aztec/aztec.js/node";
import { EmbeddedWallet } from "@aztec/wallets/embedded";

import { BeaconElProofContract } from "./artifacts/BeaconElProof.js";

interface ProofFile {
  beacon_block_root: string;
  el_state_root: string;
  proof: string[];
}

const NODE_URL = process.env.AZTEC_NODE_URL ?? "http://localhost:8080";
const PROOF_PATH = process.argv[2] ?? "proof-14190879.json";
const MODE = process.env.MODE ?? "simulate";
const PROVER = process.env.PXE_PROVER ?? (MODE === "send" ? "wasm" : "none");

const hexToBytes = (h: string): number[] =>
  Array.from(Buffer.from(h.replace(/^0x/, ""), "hex"));

const proofFile = JSON.parse(
  readFileSync(resolve(PROOF_PATH), "utf8"),
) as ProofFile;

const elRoot = hexToBytes(proofFile.el_state_root);
const beaconRoot = hexToBytes(proofFile.beacon_block_root);
const path = proofFile.proof.map(hexToBytes);

if (elRoot.length !== 32) {
  throw new Error(`expected 32-byte el_state_root, got ${elRoot.length}`);
}
if (beaconRoot.length !== 32) {
  throw new Error(`expected 32-byte beacon_block_root, got ${beaconRoot.length}`);
}
if (path.length !== 12 || path.some((p) => p.length !== 32)) {
  throw new Error(`expected 12 × 32-byte proof, got ${path.length} entries`);
}

if (PROVER === "native") {
  await Barretenberg.initSingleton({ backend: BackendType.NativeUnixSocket });
} else if (PROVER === "wasm") {
  await Barretenberg.initSingleton({ backend: BackendType.Wasm });
}

const node = createAztecNodeClient(NODE_URL);
const wallet = await EmbeddedWallet.create(node, {
  ephemeral: true,
  pxeConfig: { proverEnabled: PROVER !== "none" },
});

const [accountData] = await getInitialTestAccountsData();
const account = await wallet.createSchnorrAccount(
  accountData.secret,
  accountData.salt,
);
const from = account.address;

// No on-chain deploy — just register the deterministic instance with the PXE.
const contract = await BeaconElProofContract.deploy(wallet).register({
  contractAddressSalt: Fr.ZERO,
});
console.log("contract address:", contract.address.toString());
console.log("prover:          ", PROVER);

try {
  if (MODE === "send") {
    const { receipt } = await contract.methods
      .verify_el_state_root(elRoot, path, beaconRoot)
      .send({ from });
    console.log("tx hash:", receipt.txHash.toString());
    console.log("status: ", receipt.status);
  } else {
    const { result } = await contract.methods
      .verify_el_state_root(elRoot, path, beaconRoot)
      .simulate({ from });
    console.log("verified:", result);
  }
} finally {
  if (PROVER !== "none") {
    await Barretenberg.destroySingleton();
  }
}
