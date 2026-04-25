# ssz-prover

Builds the SSZ Merkle proof consumed by `../src/main.nr` (TXE test fixture).

All commands run from this `ts/` directory.

## Setup

```sh
cd ts
yarn install
```

Create `.env`:

```
BEACON_RPC_URL=...   # required, standard Beacon API base URL
EL_RPC_URL=...       # optional, used to cross-check via eth_getBlockByHash
```

## Run

```sh
yarn build-proof                  # default slot 14190879
yarn build-proof <slot>           # by slot
yarn build-proof 0x<beacon_root>  # by beacon block root
yarn build-proof finalized        # any beacon API block_id
```

Writes `proof-<slot>.json` and `../src/fixture.nr`.
