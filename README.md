# BeaconElProof

Aztec Noir contract that verifies an Ethereum execution-layer state root is
contained inside a beacon block root via an SSZ Merkle proof.

## Layout

- `src/beacon_el_proof.nr` — contract entry (`BeaconElProof`)
- `src/beacon_el_proof/{verifier,fixture}.nr` — submodules
- `ts/` — TS prover; generates `proof-<slot>.json` and writes `src/beacon_el_proof/fixture.nr`

## Local deploy

Requires the Aztec toolchain (`aztec`, `aztec-wallet`, `nargo`) installed via
`install.aztec.network` at version `4.2.0-aztecnr-rc.2` or compatible.

```bash
# 1. Start the local network (PXE + node on :8080, anvil L1 on :8545)
aztec start --local-network

# 2. Compile (in another terminal, from repo root)
aztec compile                      # → target/ssz-BeaconElProof.json

# 3. Load the prefunded test accounts into the wallet
aztec-wallet import-test-accounts  # registers test0, test1, ...

# 4. Deploy (no initializer on this contract)
aztec-wallet deploy ./target/ssz-BeaconElProof.json \
  --from accounts:test0 -a beacon_el_proof --no-init

# 5. Call it
aztec-wallet simulate hello_world \
  --from test0 --contract-address contracts:beacon_el_proof
```

## Generate a real proof and verify it

```bash
cd ts && yarn install
yarn build-proof <slot>            # writes ../src/beacon_el_proof/fixture.nr
cd .. && nargo test                # runs verify_real_proof against the fixture
```
