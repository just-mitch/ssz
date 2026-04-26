/-!
# Lean 4 spec for `src/beacon_el_proof/verifier.nr`

Models SHA256 as an opaque function `H : Digest → Digest → Digest` and
verifies the *tree-walking* logic of `verify_merkle_proof` against an
inductive `MTree`.

What this catches:
  * Algorithmic soundness bugs: wrong bit order, off-by-one depth, wrong
    terminator, wrong gindex composition for the EL state root.

What this does NOT catch:
  * Underconstrained-circuit bugs in the Noir → ACIR compilation
    (e.g. compiler-generated bit decompositions that don't fully pin
    every bit, `select` patterns with under-specified conditions, etc.).
    Those live below the source-language semantics and need a tool that
    operates on ACIR.

Build (requires only core Lean 4, no Mathlib):
  elan default leanprover/lean4:v4.11.0
  lean lean/Verifier.lean

Status legend in this file:
  ✓  proved
  ✗  stated, body is `sorry` (proof strategy in the docstring)
-/

namespace SszVerifier

/-! ## Abstract hash and digest -/

/-- 32-byte digest. Treated abstractly: byte-level structure is irrelevant
    to the tree-walking proof. -/
axiom Digest : Type

/-- Decidable equality on digests (the Noir code's `bytes32_eq`). -/
@[instance] axiom Digest.instDecidableEq : DecidableEq Digest

/-- Opaque hash: parent = `H(left, right)`. Stands in for
    `sha256(left || right)`. We assume nothing about it; soundness
    statements are therefore *collision-relative*. -/
axiom H : Digest → Digest → Digest

/-! ## Merkle tree spec -/

/-- Perfect binary tree of depth `d` with `Digest`s at the leaves. -/
inductive MTree : Nat → Type
  | leaf : Digest → MTree 0
  | node : {d : Nat} → MTree d → MTree d → MTree (d + 1)

namespace MTree

/-- Hash root of a tree under `H`. -/
noncomputable def root : ∀ {d}, MTree d → Digest
  | 0,     .leaf x   => x
  | _ + 1, .node l r => H (root l) (root r)

/-- Bound helper: if `i.val ≥ 2^d` and `i.val < 2^(d+1)` then
    `i.val - 2^d < 2^d`. -/
private theorem sub_lt_of_lt_two_pow_succ
    {d i : Nat} (h₁ : 2 ^ d ≤ i) (h₂ : i < 2 ^ (d + 1)) :
    i - 2 ^ d < 2 ^ d := by
  rw [Nat.pow_succ] at h₂
  omega

/-- Leaf at position `i`, where bit `d-1` of `i` selects the root's child,
    …, bit 0 selects the deepest split. -/
def leafAt : ∀ {d}, MTree d → Fin (2 ^ d) → Digest
  | 0,     .leaf x,   _ => x
  | d + 1, .node l r, ⟨i, hi⟩ =>
      if h : i < 2 ^ d then
        leafAt l ⟨i, h⟩
      else
        leafAt r ⟨i - 2 ^ d,
          sub_lt_of_lt_two_pow_succ (Nat.le_of_not_lt h) hi⟩

/-- Merkle proof for position `i`, ordered leaf → root.
    `(proofAt t i)[0]` is the leaf's immediate sibling;
    `(proofAt t i)[d-1]` is the sibling of the root's child. -/
noncomputable def proofAt : ∀ {d}, MTree d → Fin (2 ^ d) → List Digest
  | 0,     .leaf _,   _ => []
  | d + 1, .node l r, ⟨i, hi⟩ =>
      if h : i < 2 ^ d then
        proofAt l ⟨i, h⟩ ++ [r.root]
      else
        proofAt r ⟨i - 2 ^ d,
          sub_lt_of_lt_two_pow_succ (Nat.le_of_not_lt h) hi⟩
        ++ [l.root]

/-- `proofAt` always has length `d`. -/
theorem proofAt_length : ∀ {d} (t : MTree d) (i : Fin (2 ^ d)),
    (t.proofAt i).length = d
  | 0,     .leaf _,   _ => rfl
  | d + 1, .node l r, ⟨i, hi⟩ => by
      simp only [proofAt]
      split
      · rename_i h
        simp [proofAt_length l ⟨i, h⟩]
      · rename_i h
        simp [proofAt_length r ⟨i - 2 ^ d, _⟩]

end MTree

/-- Generalized index: leaves of a depth-`d` tree have gindex `2^d + i`.
    Root has gindex 1; the bit-length is exactly `d + 1`. -/
def gindex (d : Nat) (i : Fin (2 ^ d)) : Nat := 2 ^ d + i.val

/-! ## Port of `verify_merkle_proof` -/

/-- One climb step. Faithful port of the loop body in `verify_merkle_proof`:

```text
    if (index & 1) == 1: concat = sibling || node
    else:                 concat = node || sibling
    node  = sha256(concat)
    index = index >> 1
```
-/
noncomputable def climbStep (sibling : Digest) (state : Digest × Nat) : Digest × Nat :=
  let (node, idx) := state
  let parent := if idx % 2 = 1 then H sibling node else H node sibling
  (parent, idx / 2)

/-- Faithful port of `verify_merkle_proof`. The `(idx = 1)` postcondition
    enforces the precondition `2^d ≤ g < 2^(d+1)` from the doc comment. -/
noncomputable def verify (leaf : Digest) (proof : List Digest)
    (g : Nat) (root : Digest) : Bool :=
  let (finalNode, finalIdx) :=
    proof.foldl (fun st s => climbStep s st) (leaf, g)
  decide (finalIdx = 1 ∧ finalNode = root)

/-! ## Climb invariant (used by completeness) -/

/-- Index identity for the left-subtree recursion: dropping the top bit of
    `upper` after one extra `^(d+1)` factor gives `2 * upper` carried by
    `^d`. Pure arithmetic. -/
private theorem index_left (upper d v : Nat) :
    upper * 2 ^ (d + 1) + v = 2 * upper * 2 ^ d + v := by
  have : upper * 2 ^ (d + 1) = 2 * upper * 2 ^ d := by
    rw [Nat.pow_succ, Nat.mul_comm (2 ^ d) 2, ← Nat.mul_assoc, Nat.mul_comm upper 2]
  omega

/-- Index identity for the right-subtree recursion: when `2^d ≤ v`, the
    `2^d` "bit" gets absorbed into `2*upper + 1` and the remainder is
    `v - 2^d`. Pure arithmetic. -/
private theorem index_right (upper d v : Nat) (h : 2 ^ d ≤ v) :
    upper * 2 ^ (d + 1) + v = (2 * upper + 1) * 2 ^ d + (v - 2 ^ d) := by
  have h1 : upper * 2 ^ (d + 1) = 2 * upper * 2 ^ d := by
    rw [Nat.pow_succ, Nat.mul_comm (2 ^ d) 2, ← Nat.mul_assoc, Nat.mul_comm upper 2]
  have h2 : (2 * upper + 1) * 2 ^ d = 2 * upper * 2 ^ d + 2 ^ d := by
    rw [Nat.add_mul, Nat.one_mul]
  omega

/-- ✓ Core invariant: foldl-climb walks correctly leaf → root.
    `upper` represents the bits of the original `gindex` above position `d`.
    With `upper = 1` this matches the actual gindex `2^d + i.val`.

    Proof by structural recursion on the depth/tree:
    * Base `d = 0`: tree is a leaf, proof is empty, foldl returns the
      starting state `(x, upper)` directly.
    * Step `d + 1` with `t = node l r`:
      - If `v < 2^d` (leaf is in left subtree), index decomposes as
        `(2*upper) * 2^d + v`. Apply IH on `l` with `upper' = 2*upper`.
        IH gives `(l.root, 2*upper)`. The final climb step folds in
        `r.root` with `idx = 2*upper`; since `(2*upper) % 2 = 0`,
        `H` is called as `H l.root r.root = t.root`. -- `idx / 2 = upper`. ✓
      - If `v ≥ 2^d` (right subtree), index decomposes as
        `(2*upper + 1) * 2^d + (v - 2^d)`. Apply IH on `r` with
        `upper' = 2*upper + 1`. The final step folds in `l.root` with
        `idx = 2*upper + 1`; `idx % 2 = 1` flips concat order to
        `H l.root r.root = t.root`, and `idx / 2 = upper`. ✓ -/
private theorem climb_eq : ∀ {d : Nat} (t : MTree d) (i : Fin (2 ^ d)) (upper : Nat),
    (t.proofAt i).foldl (fun st s => climbStep s st)
        (t.leafAt i, upper * 2 ^ d + i.val) = (t.root, upper)
  | 0, .leaf x, i, upper => by
      simp [MTree.proofAt, MTree.leafAt, MTree.root]
  | d + 1, .node l r, ⟨v, hv⟩, upper => by
      simp only [MTree.leafAt, MTree.proofAt, MTree.root]
      by_cases h : v < 2 ^ d
      · -- Left subtree: bit `d` of (upper * 2^(d+1) + v) is 0.
        simp only [dif_pos h, List.foldl_append]
        rw [index_left upper d v, climb_eq l ⟨v, h⟩ (2 * upper)]
        simp only [List.foldl_cons, List.foldl_nil, climbStep]
        have hmod : (2 * upper) % 2 = 0 := Nat.mul_mod_right 2 upper
        have hdiv : (2 * upper) / 2 = upper := by omega
        simp [hmod, hdiv]
      · -- Right subtree: bit `d` of (upper * 2^(d+1) + v) is 1.
        have hge : 2 ^ d ≤ v := Nat.le_of_not_lt h
        simp only [dif_neg h, List.foldl_append]
        rw [index_right upper d v hge,
            climb_eq r ⟨v - 2 ^ d, MTree.sub_lt_of_lt_two_pow_succ hge hv⟩ (2 * upper + 1)]
        simp only [List.foldl_cons, List.foldl_nil, climbStep]
        have hmod : (2 * upper + 1) % 2 = 1 := by omega
        have hdiv : (2 * upper + 1) / 2 = upper := by omega
        simp [hmod, hdiv]

/-! ## Theorems -/

/-! ### ✓ Completeness
The honest prover always succeeds. Follows directly from `climb_eq` with
`upper = 1`, since `gindex d i = 2^d + i.val = 1 * 2^d + i.val`. -/
theorem verify_complete {d : Nat} (t : MTree d) (i : Fin (2 ^ d)) :
    verify (t.leafAt i) (t.proofAt i) (gindex d i) t.root = true := by
  have h := climb_eq t i 1
  rw [Nat.one_mul] at h
  unfold verify gindex
  rw [h]
  simp

/-! ### ✓ Soundness modulo collisions
Strongest soundness available without a concrete hash: two distinct
witnesses for the same `(g, root)` ⇒ a collision in `H`.

Proof strategy: induction on `d`. If both witnesses verify and differ,
then either they differ at the leaf (and the first foldl step gives two
inputs to `H` with the same output ⇒ collision), or they agree at the
leaf and differ at some deeper sibling (recurse on the climb). -/
theorem verify_sound_via_collision
    {d : Nat} (g : Nat) (r : Digest)
    (l₁ l₂ : Digest) (p₁ p₂ : List Digest)
    (hp₁ : p₁.length = d) (hp₂ : p₂.length = d)
    (h₁ : verify l₁ p₁ g r = true)
    (h₂ : verify l₂ p₂ g r = true)
    (hne : (l₁, p₁) ≠ (l₂, p₂)) :
    ∃ a b a' b' : Digest, (a, b) ≠ (a', b') ∧ H a b = H a' b' := by
  induction d generalizing g l₁ l₂ p₁ p₂ with
  | zero =>
    cases p₁ with
    | cons _ _ => simp at hp₁
    | nil =>
    cases p₂ with
    | cons _ _ => simp at hp₂
    | nil =>
      simp only [verify, List.foldl_nil, decide_eq_true_eq] at h₁ h₂
      apply absurd _ hne
      show (l₁, ([] : List Digest)) = (l₂, [])
      rw [h₁.2, h₂.2]
  | succ d ih =>
    cases p₁ with
    | nil => simp at hp₁
    | cons s₁ rest₁ =>
    cases p₂ with
    | nil => simp at hp₂
    | cons s₂ rest₂ =>
      have hp₁' : rest₁.length = d := by simpa using hp₁
      have hp₂' : rest₂.length = d := by simpa using hp₂
      -- One climb step turns `verify l (s :: rest) g r` into a verification
      -- of the rest of the proof against `g/2`. Definitional equality.
      have step : ∀ (l s : Digest) (rest : List Digest),
          verify l (s :: rest) g r =
            verify (if g % 2 = 1 then H s l else H l s) rest (g / 2) r := by
        intros; rfl
      rw [step l₁ s₁ rest₁] at h₁
      rw [step l₂ s₂ rest₂] at h₂
      by_cases hg : g % 2 = 1
      · -- Concat order is `sibling || node`, so node = H sibling leaf.
        rw [if_pos hg] at h₁ h₂
        by_cases heq : (H s₁ l₁, rest₁) = (H s₂ l₂, rest₂)
        · -- Same intermediate state ⇒ collision at this level.
          have hnode : H s₁ l₁ = H s₂ l₂ := congrArg Prod.fst heq
          have hrest : rest₁ = rest₂ := congrArg Prod.snd heq
          -- If both `(l, s)` were equal we'd have `(l₁, p₁) = (l₂, p₂)`.
          have hp_ne : ¬ (l₁ = l₂ ∧ s₁ = s₂) := by
            rintro ⟨rfl, rfl⟩
            exact hne (by rw [hrest])
          refine ⟨s₁, l₁, s₂, l₂, ?_, hnode⟩
          intro h
          exact hp_ne ⟨congrArg Prod.snd h, congrArg Prod.fst h⟩
        · exact ih (g/2) (H s₁ l₁) (H s₂ l₂) rest₁ rest₂ hp₁' hp₂' h₁ h₂ heq
      · -- Concat order is `node || sibling`, so node = H leaf sibling.
        rw [if_neg hg] at h₁ h₂
        by_cases heq : (H l₁ s₁, rest₁) = (H l₂ s₂, rest₂)
        · have hnode : H l₁ s₁ = H l₂ s₂ := congrArg Prod.fst heq
          have hrest : rest₁ = rest₂ := congrArg Prod.snd heq
          have hp_ne : ¬ (l₁ = l₂ ∧ s₁ = s₂) := by
            rintro ⟨rfl, rfl⟩
            exact hne (by rw [hrest])
          refine ⟨l₁, s₁, l₂, s₂, ?_, hnode⟩
          intro h
          exact hp_ne ⟨congrArg Prod.fst h, congrArg Prod.snd h⟩
        · exact ih (g/2) (H l₁ s₁) (H l₂ s₂) rest₁ rest₂ hp₁' hp₂' h₁ h₂ heq

/-! ### ✓ Bad-shape rejection
`g` must lie in `[2^d, 2^(d+1))` or verification fails — this is the
contract on `gindex` written in the verifier's docstring. -/

/-- ✓ The index part of the climb-fold is independent of the proof contents
    and depth: each step halves it, so after `proof.length` steps the index
    is `g / 2^proof.length`. -/
private theorem foldl_idx_eq (proof : List Digest) (leaf : Digest) (g : Nat) :
    (proof.foldl (fun st s => climbStep s st) (leaf, g)).2 = g / 2 ^ proof.length := by
  induction proof generalizing leaf g with
  | nil => simp
  | cons s rest ih =>
    show (rest.foldl (fun st x => climbStep x st) (climbStep s (leaf, g))).2 =
         g / 2 ^ (rest.length + 1)
    rw [show climbStep s (leaf, g) =
          ((if g % 2 = 1 then H s leaf else H leaf s), g / 2) from rfl,
        ih, Nat.pow_succ, Nat.div_div_eq_div_mul, Nat.mul_comm 2 (2 ^ rest.length)]

theorem verify_rejects_small_gindex
    {d : Nat} (g : Nat) (hg : g < 2 ^ d)
    (leaf : Digest) (proof : List Digest) (hp : proof.length = d)
    (root : Digest) :
    verify leaf proof g root = false := by
  -- foldl shifts d times; an initial g < 2^d ends at 0, so `idx = 1` fails.
  have hidx : (proof.foldl (fun st s => climbStep s st) (leaf, g)).2 = 0 := by
    rw [foldl_idx_eq, hp]
    exact Nat.div_eq_of_lt hg
  show decide ((proof.foldl (fun st s => climbStep s st) (leaf, g)).2 = 1 ∧
               (proof.foldl (fun st s => climbStep s st) (leaf, g)).1 = root) = false
  rw [hidx]
  rfl

theorem verify_rejects_large_gindex
    {d : Nat} (g : Nat) (hg : 2 ^ (d + 1) ≤ g)
    (leaf : Digest) (proof : List Digest) (hp : proof.length = d)
    (root : Digest) :
    verify leaf proof g root = false := by
  -- After d shifts an initial g ≥ 2^(d+1) ends at ≥ 2, so `idx = 1` fails.
  have hidx_ge : 2 ≤ (proof.foldl (fun st s => climbStep s st) (leaf, g)).2 := by
    rw [foldl_idx_eq, hp]
    apply (Nat.le_div_iff_mul_le (Nat.two_pow_pos d)).mpr
    rw [Nat.mul_comm, ← Nat.pow_succ]
    exact hg
  show decide ((proof.foldl (fun st s => climbStep s st) (leaf, g)).2 = 1 ∧
               (proof.foldl (fun st s => climbStep s st) (leaf, g)).1 = root) = false
  apply decide_eq_false
  rintro ⟨h1, _⟩
  rw [h1] at hidx_ge
  exact absurd hidx_ge (by decide)

/-! ## ✓ EL state root constants

These are the parts we can prove unconditionally with `decide`, because
they involve no hashing — they verify the doc table at lines 51–58 of
`verifier.nr` and the value of `EL_STATE_ROOT_GINDEX` (line 59). -/

namespace ELStateRoot

/-- Compose two SSZ container layers. The outer container's
    field-of-interest has gindex `g₁`; that field is the root of an
    inner container whose own field has gindex `g₂`. The combined
    gindex drops the leading `1` of `g₂` and appends its remaining bits
    onto `g₁`. -/
def composeGindex (g₁ g₂ : Nat) : Nat :=
  let k := Nat.log2 g₂
  g₁ * 2 ^ k + (g₂ - 2 ^ k)

/-- BeaconBlockHeader is 8-wide; `body_root` is field 4. -/
def headerBodyRoot : Nat := 8 + 4              -- 12,  binary 1100

/-- BeaconBlockBody is 16-wide; `execution_payload` is field 9. -/
def bodyExecPayload : Nat := 16 + 9            -- 25,  binary 11001

/-- ExecutionPayload is 32-wide; `state_root` is field 2. -/
def payloadStateRoot : Nat := 32 + 2           -- 34,  binary 100010

/-- Composed EL-state-root gindex per the doc table. -/
def elStateRoot : Nat :=
  composeGindex (composeGindex headerBodyRoot bodyExecPayload) payloadStateRoot

/-- ✓ The Noir constant `EL_STATE_ROOT_GINDEX = 6434` matches the
    composition of the three SSZ container layers. -/
theorem matches_noir_constant : elStateRoot = 6434 := by decide

/-- ✓ Intermediate composition: `BeaconBlockHeader → BeaconBlockBody`
    yields gindex 201 (binary 11001001). -/
theorem header_body_compose : composeGindex headerBodyRoot bodyExecPayload = 201 := by
  decide

/-- ✓ `EL_STATE_ROOT_DEPTH = 12 = floor(log2 6434)`. -/
theorem depth_eq : Nat.log2 6434 = 12 := by decide

/-- ✓ The constant satisfies the precondition of `verify_merkle_proof`,
    `2^DEPTH ≤ g < 2^(DEPTH+1)`. -/
theorem in_depth_12_range : 2 ^ 12 ≤ 6434 ∧ 6434 < 2 ^ 13 := by decide

/-- ✓ Bit-by-bit decomposition of 6434 (LSB on the left, matching the
    order in which `verify_merkle_proof` consumes the index via
    `index & 1` then `index >> 1`). The bit string is `1100100100010`. -/
theorem bit_decomposition :
    (6434 >>> 0)  &&& 1 = 0 ∧   -- depth 0  (leaf level): right child? no
    (6434 >>> 1)  &&& 1 = 1 ∧   -- depth 1
    (6434 >>> 2)  &&& 1 = 0 ∧
    (6434 >>> 3)  &&& 1 = 0 ∧
    (6434 >>> 4)  &&& 1 = 0 ∧
    (6434 >>> 5)  &&& 1 = 1 ∧
    (6434 >>> 6)  &&& 1 = 0 ∧
    (6434 >>> 7)  &&& 1 = 0 ∧
    (6434 >>> 8)  &&& 1 = 1 ∧
    (6434 >>> 9)  &&& 1 = 0 ∧
    (6434 >>> 10) &&& 1 = 0 ∧
    (6434 >>> 11) &&& 1 = 1 ∧
    (6434 >>> 12) &&& 1 = 1 ∧   -- terminator bit
    (6434 >>> 13) &&& 1 = 0 := by
  decide

end ELStateRoot

end SszVerifier
