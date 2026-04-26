// Run a verify_el_state_root call against the BeaconElProof contract on the
// Aztec local network.
//
// The contract has no public functions and no initializer, so it does not need
// to be "deployed" on-chain. We compute its deterministic address from the
// artifact + zero salt and register it locally with the PXE — that's enough to
// simulate, prove, or send a tx.
//
// Usage:
//   yarn submit                         # default proof file, simulate verify
//   yarn submit proof-14190879.json     # specific proof
//   MODE=send  yarn submit              # broadcast verify tx (real client-side proof)
//   MODE=prove TARGET=hello yarn submit # prove hello_world only — no broadcast
//   MODE=prove TARGET=bench yarn submit # prove hello_world + verify, compare timings
//
// Env:
//   AZTEC_NODE_URL    default http://localhost:8080
//   MODE              "simulate" (default), "prove" (proves only, no tx), or "send"
//   TARGET            "verify" (default), "hello", or "bench"
//   PXE_PROVER        "wasm" (default for prove/send), "native" (needs BB_BINARY_PATH),
//                     or "none". simulate ignores this and runs unproven.

import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { performance } from "node:perf_hooks";

import { getInitialTestAccountsData } from "@aztec/accounts/testing";
import { Fr } from "@aztec/aztec.js/fields";
import { createAztecNodeClient } from "@aztec/aztec.js/node";
import { BackendType, Barretenberg } from "@aztec/bb.js";
import { EmbeddedWallet } from "@aztec/wallets/embedded";

import { BeaconElProofContract } from "./artifacts/BeaconElProof.js";

interface ProofFile {
  beacon_block_root: string;
  el_state_root: string;
  proof: string[];
}

type Target = "verify" | "hello" | "bench";
type Mode = "simulate" | "prove" | "send";

const NODE_URL = process.env.AZTEC_NODE_URL ?? "http://localhost:8080";
const PROOF_PATH = process.argv[2] ?? "proof-14190879.json";
const MODE = (process.env.MODE ?? "simulate") as Mode;
const TARGET = (process.env.TARGET ?? "verify") as Target;
const PROVER =
  process.env.PXE_PROVER ?? (MODE === "simulate" ? "none" : "wasm");

if (MODE !== "simulate" && MODE !== "prove" && MODE !== "send") {
  throw new Error(`unknown MODE=${MODE}; expected simulate | prove | send`);
}
if (TARGET !== "verify" && TARGET !== "hello" && TARGET !== "bench") {
  throw new Error(`unknown TARGET=${TARGET}; expected verify | hello | bench`);
}

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
  throw new Error(
    `expected 32-byte beacon_block_root, got ${beaconRoot.length}`,
  );
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
console.log("mode:            ", MODE);
console.log("target:          ", TARGET);

const fmtMs = (ms: number): string => `${ms.toFixed(0)} ms`;

interface ProveResult {
  wall: number;
  proving: number;
  total: number;
  perFunction: { functionName: string; time: number }[];
}

const proveHello = async (): Promise<ProveResult> => {
  const t0 = performance.now();
  const profile = await contract.methods.hello_world().profile({
    from,
    profileMode: "execution-steps",
    skipProofGeneration: false,
  });
  const wall = performance.now() - t0;
  const { proving = 0, total, perFunction } = profile.stats.timings;
  console.log(
    `[hello] proving: ${fmtMs(proving)}  total: ${fmtMs(total)}  wall: ${fmtMs(wall)}`,
  );
  return { wall, proving, total, perFunction };
};

const proveVerify = async (): Promise<ProveResult> => {
  const t0 = performance.now();
  const profile = await contract.methods
    .verify_el_state_root(elRoot, path, beaconRoot)
    .profile({
      from,
      profileMode: "execution-steps",
      skipProofGeneration: false,
    });
  const wall = performance.now() - t0;
  const { proving = 0, total, perFunction } = profile.stats.timings;
  console.log(
    `[verify] proving: ${fmtMs(proving)}  total: ${fmtMs(total)}  wall: ${fmtMs(wall)}`,
  );
  return { wall, proving, total, perFunction };
};

const sendHello = async (): Promise<number> => {
  const t0 = performance.now();
  const { receipt } = await contract.methods.hello_world().send({ from });
  const wall = performance.now() - t0;
  console.log("[hello] tx hash:", receipt.txHash.toString());
  console.log("[hello] status: ", receipt.status);
  console.log("[hello] wall:   ", fmtMs(wall));
  return wall;
};

const sendVerify = async (): Promise<number> => {
  const t0 = performance.now();
  const { receipt } = await contract.methods
    .verify_el_state_root(elRoot, path, beaconRoot)
    .send({ from });
  const wall = performance.now() - t0;
  console.log("[verify] tx hash:", receipt.txHash.toString());
  console.log("[verify] status: ", receipt.status);
  console.log("[verify] wall:   ", fmtMs(wall));
  return wall;
};

const simulateHello = async (): Promise<void> => {
  const { result } = await contract.methods.hello_world().simulate({ from });
  console.log("[hello] result:", result);
};

const simulateVerify = async (): Promise<void> => {
  const { result } = await contract.methods
    .verify_el_state_root(elRoot, path, beaconRoot)
    .simulate({ from });
  console.log("[verify] verified:", result);
};

const printBench = (hello: ProveResult, verify: ProveResult): void => {
  const ratio = verify.proving / hello.proving;
  console.log("\n=== bench summary (proving only, no broadcast) ===");
  console.log(`hello_world          : ${fmtMs(hello.proving)}`);
  console.log(`verify_el_state_root : ${fmtMs(verify.proving)}`);
  console.log(`ratio (verify/hello) : ${ratio.toFixed(2)}x`);
  console.log(
    `delta                : ${fmtMs(verify.proving - hello.proving)}`,
  );
};

try {
  if (MODE === "send") {
    if (TARGET === "hello") {
      await sendHello();
    } else if (TARGET === "verify") {
      await sendVerify();
    } else {
      const helloMs = await sendHello();
      const verifyMs = await sendVerify();
      console.log("\n=== bench summary (send wall-clock) ===");
      console.log(`hello_world          : ${fmtMs(helloMs)}`);
      console.log(`verify_el_state_root : ${fmtMs(verifyMs)}`);
      console.log(`ratio (verify/hello) : ${(verifyMs / helloMs).toFixed(2)}x`);
      console.log(`delta                : ${fmtMs(verifyMs - helloMs)}`);
    }
  } else if (MODE === "prove") {
    if (TARGET === "hello") {
      await proveHello();
    } else if (TARGET === "verify") {
      await proveVerify();
    } else {
      const hello = await proveHello();
      const verify = await proveVerify();
      printBench(hello, verify);
    }
  } else {
    if (TARGET === "hello") {
      await simulateHello();
    } else if (TARGET === "verify") {
      await simulateVerify();
    } else {
      await simulateHello();
      await simulateVerify();
    }
  }
} finally {
  if (PROVER !== "none") {
    await Barretenberg.destroySingleton();
  }
}
