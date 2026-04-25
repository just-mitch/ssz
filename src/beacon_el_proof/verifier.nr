//! SSZ-style single-leaf Merkle proof verification using SHA256.
//!
//! Hashing convention: every internal node = sha256(left_child || right_child).
//! The leaf's path is encoded as a generalized index: the root has index 1,
//! and a node at index `g` has children `2g` (left) and `2g + 1` (right).
//! Bit 0 of the current index tells us whether we are the right (1) or left (0)
//! child of our parent.

/// Verify that `leaf` lives at generalized index `gindex` in a Merkle tree
/// committed by `root`, given `proof` -- the sibling at each level from leaf
/// up to (but not including) the root.
///
/// `gindex` must satisfy `2^DEPTH <= gindex < 2^(DEPTH+1)` -- i.e. its
/// bit-length is exactly `DEPTH + 1`. If it doesn't, verification fails
/// (returns false) rather than panicking.
pub fn verify_merkle_proof<let DEPTH: u32>(
    leaf: [u8; 32],
    proof: [[u8; 32]; DEPTH],
    gindex: u64,
    root: [u8; 32],
) -> bool {
    let mut node = leaf;
    let mut index = gindex;

    for i in 0..DEPTH {
        let sibling = proof[i];
        let mut concat: [u8; 64] = [0; 64];

        if (index & 1) == 1 {
            for j in 0..32 {
                concat[j] = sibling[j];
                concat[j + 32] = node[j];
            }
        } else {
            for j in 0..32 {
                concat[j] = node[j];
                concat[j + 32] = sibling[j];
            }
        }

        node = sha256::sha256_var(concat, concat.len());
        index = index >> 1;
    }

    (index == 1) & bytes32_eq(node, root)
}

/// Generalized index of `state_root` inside a beacon block, composed across
/// the three SSZ container layers:
///
/// | Container          | Width | Field idx                   | gindex |
/// |--------------------|-------|-----------------------------|--------|
/// | BeaconBlockHeader  |   8   |  4 (body_root)              |   12   |
/// | BeaconBlockBody    |  16   |  9 (execution_payload)      |   25   |
/// | ExecutionPayload   |  32   |  2 (state_root)             |   34   |
///
/// Concatenated bit paths: 1100 || 1001 || 00010 = 1100100100010 = 6434.
/// Total depth = floor(log2(6434)) = 12.
pub global EL_STATE_ROOT_GINDEX: u64 = 6434;
pub global EL_STATE_ROOT_DEPTH: u32 = 12;

/// Specialization of [`verify_merkle_proof`] for the EL-state-root proof.
pub fn verify_el_state_root_in_beacon_root(
    el_state_root: [u8; 32],
    proof: [[u8; 32]; 12],
    beacon_block_root: [u8; 32],
) -> bool {
    verify_merkle_proof(el_state_root, proof, EL_STATE_ROOT_GINDEX, beacon_block_root)
}

fn bytes32_eq(a: [u8; 32], b: [u8; 32]) -> bool {
    let mut equal = true;
    for i in 0..32 {
        if a[i] != b[i] {
            equal = false;
        }
    }
    equal
}

/// Hash two child nodes together -- exposed for tests and for prover-side
/// consistency checks.
pub fn merkle_parent(left: [u8; 32], right: [u8; 32]) -> [u8; 32] {
    let mut concat: [u8; 64] = [0; 64];
    for i in 0..32 {
        concat[i] = left[i];
        concat[i + 32] = right[i];
    }
    sha256::sha256_var(concat, concat.len())
}

mod tests {
    use super::{merkle_parent, verify_merkle_proof};

    #[test]
    unconstrained fn verify_depth_1_left_leaf() {
        let left: [u8; 32] = [0x11; 32];
        let right: [u8; 32] = [0x22; 32];
        let root = merkle_parent(left, right);

        // Left leaf -> gindex 2 (binary 10).
        assert(verify_merkle_proof(left, [right], 2, root));
    }

    #[test]
    unconstrained fn verify_depth_1_right_leaf() {
        let left: [u8; 32] = [0x11; 32];
        let right: [u8; 32] = [0x22; 32];
        let root = merkle_parent(left, right);

        // Right leaf -> gindex 3 (binary 11).
        assert(verify_merkle_proof(right, [left], 3, root));
    }

    #[test]
    unconstrained fn verify_depth_3_arbitrary_leaf() {
        // Build an 8-leaf tree by hand and verify leaf #5.
        let l0: [u8; 32] = [0x10; 32];
        let l1: [u8; 32] = [0x11; 32];
        let l2: [u8; 32] = [0x12; 32];
        let l3: [u8; 32] = [0x13; 32];
        let l4: [u8; 32] = [0x14; 32];
        let l5: [u8; 32] = [0x15; 32];
        let l6: [u8; 32] = [0x16; 32];
        let l7: [u8; 32] = [0x17; 32];

        let h01 = merkle_parent(l0, l1);
        let h23 = merkle_parent(l2, l3);
        let h45 = merkle_parent(l4, l5);
        let h67 = merkle_parent(l6, l7);
        let h0123 = merkle_parent(h01, h23);
        let h4567 = merkle_parent(h45, h67);
        let root = merkle_parent(h0123, h4567);

        // l5 sits at gindex 8 + 5 = 13 (binary 1101). Sibling order leaf->root:
        // l4 at depth 0, h67 at depth 1, h0123 at depth 2.
        let proof: [[u8; 32]; 3] = [l4, h67, h0123];
        assert(verify_merkle_proof(l5, proof, 13, root));
    }

    #[test]
    unconstrained fn rejects_wrong_root() {
        let left: [u8; 32] = [0x11; 32];
        let right: [u8; 32] = [0x22; 32];
        let bogus: [u8; 32] = [0xff; 32];

        assert(!verify_merkle_proof(left, [right], 2, bogus));
    }

    #[test]
    unconstrained fn rejects_wrong_gindex() {
        let left: [u8; 32] = [0x11; 32];
        let right: [u8; 32] = [0x22; 32];
        let root = merkle_parent(left, right);

        // Claim the left leaf is the right leaf -> concat order flips.
        assert(!verify_merkle_proof(left, [right], 3, root));
    }

    #[test]
    unconstrained fn rejects_wrong_depth_gindex() {
        let left: [u8; 32] = [0x11; 32];
        let right: [u8; 32] = [0x22; 32];
        let root = merkle_parent(left, right);

        // gindex 4 (binary 100) implies a depth-2 proof, but we only supply 1.
        // After 1 shift, index = 2, not 1, so verification must fail.
        assert(!verify_merkle_proof(left, [right], 4, root));
    }
}
