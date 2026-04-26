# Beacon EL Proof

Aztec Noir contract that verifies an Ethereum execution-layer state root is
contained inside a beacon block root via an SSZ Merkle proof.

## Purpose

This repo gathers data for [AztecProtocol/governance#13](https://github.com/AztecProtocol/governance/pull/13):
specifically, the cost of including only a beacon block hash in Aztec's global
variables (and proving inclusion in app circuits) versus including the EL state root
directly. It also doubles as a test of Claude on formal methods (Lean) and basic
contract benchmarking. See [PROGRESSION.md](./PROGRESSION.md) for the development path.

## Layout

- `src/beacon_el_proof.nr` — contract entry (`BeaconElProof`)
- `src/beacon_el_proof/{verifier,fixture}.nr` — submodules
- `ts/` — TS prover and call script; generates `proof-<slot>.json` and writes `src/beacon_el_proof/fixture.nr`
- `forge/` — Solidity L1-side check (EIP-4788 beacon-roots ring buffer)
- `lean/` — Lean formalization of the verifier (soundness, completeness, rejection theorems)

## Local network setup

Requires the Aztec toolchain (`aztec`, `nargo`) installed via
`install.aztec.network` at version `4.2.0` or compatible.

```bash
# 1. Start the local network (PXE + node on :8080, anvil L1 on :8545)
aztec start --local-network

# 2. Compile (in another terminal, from repo root)
aztec compile                      # → target/ssz-BeaconElProof.json
```

The contract has no public functions and no initializer, so it does **not**
need an on-chain deploy step — both `simulate` and `send` work after a local
PXE registration done by the call script below.

## Generate a real proof and verify it (Noir TXE test)

```bash
cd ts && yarn install
yarn build-proof <slot>            # writes ../src/beacon_el_proof/fixture.nr
cd .. && aztec test                # runs verify_real_proof against the fixture
```

## Submit a verify_el_state_root call

```bash
cd ts
yarn codegen                       # → src/artifacts/BeaconElProof.ts

# Simulate (returns the bool locally, no tx, no fee, no proof)
yarn submit proof-14190879.json

# Broadcast a tx with a real client-side proof (wasm prover, default)
MODE=send yarn submit proof-14190879.json

# Native prover (auto-discovers the bb binary bundled with @aztec/bb.js)
MODE=send PXE_PROVER=native yarn submit proof-14190879.json

# Send without proof generation (local-network accepts unproven txs)
MODE=send PXE_PROVER=none yarn submit proof-14190879.json
```

`src/submit.ts` reads `proof-<slot>.json`, computes the contract's deterministic
address and registers the instance with the local PXE (no on-chain deploy),
funds itself with the first prefunded test account, and invokes
`verify_el_state_root`.

## Benchmark proving time (no broadcast)

### Gate counts

App-circuit gate counts can be inspected directly with `aztec profile gates`:

```
ssz-BeaconElProof::hello_world                  5,524
ssz-BeaconElProof::verify_el_state_root       113,758
```

### Proving times


```bash
cd ts

# WASM prover (default; portable, slower)
MODE=prove TARGET=bench PXE_PROVER=wasm   yarn submit proof-<slot>.json

# Native prover (~2x faster on Apple Silicon; uses the bundled bb)
MODE=prove TARGET=bench PXE_PROVER=native yarn submit proof-<slot>.json
```

`MODE=prove` runs the full client-side prover via PXE `profileTx` and reports
`stats.timings.proving` — no tx is sent, no fee is paid, no sequencer involved.
`TARGET=bench` runs both `hello_world` and `verify_el_state_root` back-to-back so
their proving cost can be compared on the same backend in the same process.

Validate end-to-end against a different beacon block before benching:

```bash
# 1. Pull a fresh proof + Noir fixture for any beacon block_id
cd ts && yarn build-proof finalized       # or a slot, or a beacon root

# 2. Confirm the circuit still verifies the new fixture
cd .. && aztec test                       # all 8 tests, incl. verify_real_proof

# 3. Re-run the prover bench against the new proof file
cd ts && MODE=prove TARGET=bench PXE_PROVER=native yarn submit proof-<new-slot>.json
```

The proving cost is dominated by the protocol kernel circuits
(init/inner/reset/tail/hiding), which run for *any* private function call.
The app circuit (`verify_el_state_root` does 12 SHA-256 compressions) sits on top,
so the verify-vs-hello delta is small and proportional in absolute terms across
backends. Sample run, slot 14199136:

| backend | hello_world | verify_el_state_root | delta  | ratio |
| ------- | ----------- | -------------------- | ------ | ----- |
| wasm    | 16.0 s      | 16.8 s               | 744 ms | 1.05x |
| native  | 7.1 s       | 7.7 s                | 571 ms | 1.08x |

Host: Apple **M2 Pro** (10 cores, 6P + 4E), 16 GB unified memory, macOS 14.5
(arm64). Toolchain: Aztec **4.2.0** (`aztec`, `nargo`, `@aztec/bb.js` 4.2.0,
bundled native `bb` 4.2.0 from `node_modules/@aztec/bb.js/build/arm64-macos/bb`),
Node v24.13.0. Both backends ran in the same process via `yarn submit`, so
`from`/contract registration/PXE state was identical between calls.

Per-call output also shows `total` (PXE end-to-end including sync + witgen) and
`wall` (process-side wall clock) so PXE overhead can be separated from BB.
