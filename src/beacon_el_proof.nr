mod verifier;
mod fixture;

use aztec::macros::aztec;

#[aztec]
contract BeaconElProof {
    use crate::verifier::verify_el_state_root_in_beacon_root;
    use aztec::macros::functions::{external, view};

    // "hello world" packed as ASCII bytes:
    // h=0x68 e=0x65 l=0x6c l=0x6c o=0x6f ' '=0x20 w=0x77 o=0x6f r=0x72 l=0x6c d=0x64
    pub global HELLO_WORLD: Field = 0x68656c6c6f20776f726c64;

    #[external("private")]
    #[view]
    fn hello_world() -> Field {
        HELLO_WORLD
    }

    /// Verify that `el_state_root` is the `state_root` of the
    /// `execution_payload` whose container chain hashes up to
    /// `beacon_block_root`. The proof is the SSZ Merkle path from the
    /// `state_root` leaf through `ExecutionPayload` -> `BeaconBlockBody` ->
    /// `BeaconBlockHeader`, ordered leaf -> root, length 12.
    #[external("private")]
    #[view]
    fn verify_el_state_root(
        el_state_root: [u8; 32],
        proof: [[u8; 32]; 12],
        beacon_block_root: [u8; 32],
    ) -> bool {
        verify_el_state_root_in_beacon_root(el_state_root, proof, beacon_block_root)
    }

    mod test {
        use crate::{fixture, BeaconElProof};
        use aztec::test::helpers::test_environment::TestEnvironment;

        #[test]
        unconstrained fn test_hello_world() {
            let mut env = TestEnvironment::new();
            let caller = env.create_light_account();
            let contract_address = env.deploy("BeaconElProof").without_initializer();

            let result = env.view_private(caller, BeaconElProof::at(contract_address).hello_world());

            assert_eq(result, 0x68656c6c6f20776f726c64);
        }

        // Verify a real beacon block produced by `cd ts && yarn build-proof <slot>`.
        // Skipped while `src/fixture.nr` still holds the placeholder.
        #[test]
        unconstrained fn verify_real_proof() {
            if !fixture::IS_PLACEHOLDER {
                let mut env = TestEnvironment::new();
                let caller = env.create_light_account();
                let contract_address = env.deploy("BeaconElProof").without_initializer();

                let ok = env.view_private(
                    caller,
                    BeaconElProof::at(contract_address).verify_el_state_root(
                        fixture::EL_STATE_ROOT,
                        fixture::PROOF,
                        fixture::BEACON_BLOCK_ROOT,
                    ),
                );

                assert(ok, "EL state root proof did not verify against beacon block root");
            }
        }
    }
}
