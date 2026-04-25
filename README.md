# BeaconElProof

Aztec Noir contract that verifies an Ethereum execution-layer state root is
contained inside a beacon block root via an SSZ Merkle proof.

## Layout

- `src/beacon_el_proof.nr` — contract entry (`BeaconElProof`)
- `src/beacon_el_proof/{verifier,fixture}.nr` — submodules
- `ts/` — TS prover; generates `proof-<slot>.json` and writes `src/beacon_el_proof/fixture.nr`

## Local deploy

Prerequisites: `aztec-up` installed (provides `nargo`, `aztec`, `aztec-wallet`).

```bash
# 1. Start the local sandbox (PXE + node on :8080, anvil L1 on :8545)
aztec start --sandbox

# 2. Compile
nargo compile                      # → target/ssz-BeaconElProof.json

# 3. Fund a deployer account (one-off)
aztec-wallet import-test-accounts
aztec-wallet create-account -a deployer --register-only
aztec-wallet bridge-fee-juice 1000000000000000000 deployer --mint --no-wait
aztec-wallet deploy-account -f deployer

# 4. Deploy the contract
aztec-wallet deploy ./target/ssz-BeaconElProof.json \
  -f deployer -a beacon_el_proof --no-init

# 5. Call it
aztec-wallet simulate hello_world -ca beacon_el_proof -f deployer
```

## Generate a real proof and verify it

```bash
cd ts && yarn install
yarn build-proof <slot>            # writes src/beacon_el_proof/fixture.nr
cd .. && nargo test                # runs verify_real_proof against the fixture
```
