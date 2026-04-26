# Development Progression

I include the following to help devs roughly see the path I took here, in the hopes it may be useful to gauge claude's effectiveness developing across aztec, ethereum, and lean.

See also https://docs.aztec.network/developers/ai_tooling. I used 
```
/plugin marketplace add critesjosh/aztec-claude-plugin
/plugin install aztec@aztec-plugins
```


## Set up

```bash
VERSION=4.2.0 bash -i <(curl -sL https://install.aztec.network/4.2.0)
aztec-up install 4.2.0
aztec new ssz
```

Use `aztec compile` / `aztec test`, never bare `nargo` (artifacts are incomplete).

## Rough Prompts

1. *"Add a simple, private hello world function and accompanying test."*
2. *"Given a candidate `el_state_root`, a beacon block, and a trusted `beacon_block_root`, verify with a Merkle proof that `el_state_root` is the `state_root` field of the `execution_payload` inside the body whose `body_root` is committed by the beacon header whose `hash_tree_root` is `beacon_block_root`. Note the SSZ rule: field `i` of an `N`-field container sits at gindex `next_pow2(N) + i`."*
3. *"Minimize the gate count reported by `aztec profile gates` while keeping the test passing."*
4. *"Get better types in `index.ts` — does viem have wrappers over these raw getters? Use `@chainsafe/persistent-merkle-tree` for SSZ so tree shape is exposed natively."*
5. *"Add a separate TX submission path that also submits a transaction to the `hello_world` endpoint. I want to bench the time needed to prove both transactions and compare them, under both `PXE_PROVER=native` and `PXE_PROVER=wasm`, on at least two fixtures, with hardware specs in the README."*
6. *"Create a new forge project in this repo to confirm EIP-4788's beacon-roots ring buffer can cheaply verify a beacon hash. Use soldeer for deps."*
7. *"Use Lean to formally verify `src/beacon_el_proof/verifier.nr`. Treat the hash as an oracle and prove the tree-walking logic modulo collision-resistance. Implement `verify_sound_via_collision`, prove `verify_rejects_small_gindex`, prove `verify_rejects_large_gindex`."*
8. *"Write the README for the [AZIP-13](https://github.com/AztecProtocol/governance/pull/13) audience: why first, then benchmarks + hardware, then an honest delineation of what's measured vs. assumed (`AZIP_DESIGN.md`)."*

