# BeaconElProof

Aztec Noir contract that verifies an Ethereum execution-layer state root is
contained inside a beacon block root via an SSZ Merkle proof.

## Layout

- `src/beacon_el_proof.nr` — contract entry (`BeaconElProof`)
- `src/beacon_el_proof/{verifier,fixture}.nr` — submodules
- `ts/` — TS prover and call script; generates `proof-<slot>.json` and writes `src/beacon_el_proof/fixture.nr`

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

# Simulate (returns the bool locally, no tx, no fee)
yarn submit proof-14190879.json

# Or broadcast a transaction
MODE=send yarn submit proof-14190879.json
```

`src/submit.ts` reads `proof-<slot>.json`, computes the contract's deterministic
address and registers the instance with the local PXE (no on-chain deploy),
funds itself with the first prefunded test account, and invokes
`verify_el_state_root`.
