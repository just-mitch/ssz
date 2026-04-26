# Lean 4 Spec for the Noir Merkle Verifier

This directory contains a machine-checked Lean 4 specification of the
single-leaf Merkle proof verifier in
[`src/beacon_el_proof/verifier.nr`](../src/beacon_el_proof/verifier.nr).

The whole spec is a single self-contained file: [`Verifier.lean`](Verifier.lean).
It depends only on Lean 4 core — no Mathlib, no other libraries.

---

## TL;DR

We model SHA256 as an opaque hash `H : Digest → Digest → Digest` and prove:

| Theorem | Plain English |
|---|---|
| `verify_complete` | The honest prover always succeeds. |
| `verify_sound_via_collision` | Two different accepting witnesses for the same `(gindex, root)` would force a SHA256 collision. |
| `verify_rejects_small_gindex` | `gindex < 2^DEPTH` ⇒ verifier returns `false`. |
| `verify_rejects_large_gindex` | `gindex ≥ 2^(DEPTH+1)` ⇒ verifier returns `false`. |
| `ELStateRoot.matches_noir_constant` | The Noir constant `EL_STATE_ROOT_GINDEX = 6434` is exactly the composition of three SSZ container layers. |
| `ELStateRoot.depth_eq` | `EL_STATE_ROOT_DEPTH = 12 = floor(log2 6434)`. |
| `ELStateRoot.in_depth_12_range` | `6434` lives in `[2^12, 2^13)`, satisfying the verifier's gindex precondition. |

If `lean Verifier.lean` exits with no warnings, every one of those holds.

---

## Build & check

```bash
# Pin Lean version (any 4.x works; 4.30 is what we tested).
elan default leanprover/lean4:v4.11.0

# Type-check the file. Clean exit ⇒ all theorems are proved.
lean lean/Verifier.lean
```

There is no `lakefile` because there is nothing to build — this is a single
file that the Lean kernel checks. A non-zero exit, an error, or a `warning:
declaration uses 'sorry'` means a proof is incomplete.

---

## Lean 4 cheat sheet

Enough syntax to read the file, in 30 seconds.

| Construct | Meaning |
|---|---|
| `axiom X : T` | `X` exists, no definition. Used here to stub SHA256. |
| `def f : T := ...` | Ordinary definition. Can be unfolded by the kernel. |
| `noncomputable def` | Same, but not compiled to bytecode (allowed because we hash with an axiom). |
| `theorem name : P := by tac` | `name` is a proof of proposition `P`, constructed by tactic block `tac`. |
| `inductive T : ... → Type` | Algebraic data type. The constructors are listed below. |
| `H : A → B → C` | Function from `A`, then `B`, to `C`. Curried. |
| `H a b` | Apply `H` to `a` then `b`. No parens. |
| `fun x => e` | Lambda. |
| `let (a, b) := pair; e` | Destructure a pair. |
| `match x with | C₁ a => e₁ | C₂ b => e₂` | Pattern match. |
| `∀ x, P x`  / `∃ x, P x` | Universal / existential. |
| `Σ x, P x`  / `Fin n` | Dependent pair / `{i : Nat // i < n}`. |
| `a = b`  / `a ≠ b` | Propositional equality / disequality. |
| `decide P` | Evaluate a `Decidable` proposition to `Bool`. |
| `¬ P` / `P → False` | Negation. Same thing under the hood. |

Comments:
- `--` line comment.
- `/-! ... -/` module/section doc, **rendered**.
- `/-- ... -/` declaration doc, **rendered**.

Tactic block (`by ...`) shorthand:
- `intro h` — assume the hypothesis (like `assume` in math).
- `exact e` — close the goal with term `e`.
- `apply f` — work backward from `f`'s conclusion.
- `rw [h]` — rewrite using equation `h`.
- `simp` — normalize using a database of rewrite rules.
- `cases x with | nil => ... | cons a b => ...` — case-split on `x`.
- `induction x with | zero => ... | succ k ih => ...` — induction on `x`.
- `rfl` — proves `a = a` (anything definitionally equal).
- `decide` — auto-discharge a goal a kernel can compute.

---

## Walkthrough

### 1. Abstract setup

```lean
axiom Digest : Type
axiom H : Digest → Digest → Digest
```

We treat the digest type and the hash function as black boxes. **Nothing in the
file assumes anything about `H`** — not even that it's deterministic across
calls (Lean functions are deterministic by definition). In particular, we do
**not** assume `H` is collision-resistant; the soundness theorem instead says
"if you can break this verifier, you've found a collision" and is therefore
*conditional* on collision resistance.

### 2. The tree spec

```lean
inductive MTree : Nat → Type
  | leaf : Digest → MTree 0
  | node : {d : Nat} → MTree d → MTree d → MTree (d + 1)
```

A `MTree d` is a perfect binary tree of depth `d`. Note that `d` is part of the
type — `MTree 3` and `MTree 5` are distinct types — which lets the type checker
guarantee that `proofAt` returns a list of exactly the right length.

```lean
noncomputable def root      : MTree d → Digest
def leafAt   (t : MTree d) (i : Fin (2^d)) : Digest
noncomputable def proofAt   (t : MTree d) (i : Fin (2^d)) : List Digest
```

`leafAt t i` reads the `i`-th leaf out of `t`.
`proofAt t i` is the canonical Merkle proof for that leaf, ordered leaf → root.
`root t` is the Merkle root.

### 3. The verifier port

```lean
def climbStep (sibling : Digest) (state : Digest × Nat) : Digest × Nat :=
  let (node, idx) := state
  let parent := if idx % 2 = 1 then H sibling node else H node sibling
  (parent, idx / 2)
```

This is one iteration of the Noir for-loop, ported faithfully:

| Noir | Lean |
|---|---|
| `if (index & 1) == 1` | `if idx % 2 = 1` |
| `concat = sibling \|\| node`, `node = sha256(concat)` | `H sibling node` |
| `concat = node \|\| sibling`, `node = sha256(concat)` | `H node sibling` |
| `index = index >> 1` | `idx / 2` |

Then `verify` is the whole loop expressed as a left-fold:

```lean
def verify (leaf : Digest) (proof : List Digest) (g : Nat) (root : Digest) : Bool :=
  let (finalNode, finalIdx) :=
    proof.foldl (fun st s => climbStep s st) (leaf, g)
  decide (finalIdx = 1 ∧ finalNode = root)
```

### 4. The theorems

#### `verify_complete` ✓

> If you start with a real tree, hand someone the canonical Merkle proof and
> the right gindex, the verifier accepts.

The proof rests on a single invariant lemma `climb_eq`: foldl-climbing through
`proofAt t i` correctly walks `t.leafAt i` up to `t.root`, while shifting the
gindex's bits one at a time.

#### `verify_sound_via_collision` ✓

> Two distinct accepting witnesses ⇒ a hash collision.

Induction on depth `d`. At depth 0, both proofs are empty, and the leaf must
equal the root, so the witnesses are forced to be equal.

At depth `d+1`, both proofs are non-empty. The first climb step turns
`verify leaf₁ (s₁ :: rest₁) g r` into `verify node₁ rest₁ (g/2) r`, and
similarly for the second witness. Two cases:

1. The intermediate `(node, rest)` pairs match. Then `node₁ = node₂` is
   `H _ _ = H _ _` over different inputs (because the witnesses differ
   somewhere among the leaf, head sibling, or rest, and the rests match).
   That's the collision.
2. Otherwise, recurse on the IH at depth `d` against `g/2`.

#### `verify_rejects_small_gindex` ✓ and `verify_rejects_large_gindex` ✓

These pin down the precondition `2^DEPTH ≤ gindex < 2^(DEPTH+1)` from the Noir
docstring. Both fall out of a single arithmetic lemma `foldl_idx_eq`:

> The index after the climb is exactly `g / 2^proof.length`.

Then:
- If `g < 2^d`, that quotient is 0, and `0 ≠ 1` ⇒ verifier rejects.
- If `g ≥ 2^(d+1)`, that quotient is `≥ 2`, and `≥ 2 ≠ 1` ⇒ verifier rejects.

#### EL-state-root constants

These are pure arithmetic on small integers — every theorem in the
`ELStateRoot` namespace is proved by `decide`, which means the Lean kernel
evaluates the expression and confirms it. They mechanically check the table at
[`verifier.nr:51-58`](../src/beacon_el_proof/verifier.nr#L51-L58) and the
constant on [line 59](../src/beacon_el_proof/verifier.nr#L59). If anyone
changes those numbers in the Noir, this file stops compiling.

---

## What this *does not* prove

The model lives at the **source-language** level. Faithful translation of the
Noir surface syntax into Lean.

That means the proof catches:

- Off-by-one bugs in the loop count or gindex bit layout.
- Wrong concat order on the `index & 1` branch.
- Wrong terminator condition.
- Wrong gindex composition for the EL state root.

It does **not** catch:

- Underconstrained ACIR (e.g. compiler-generated bit decompositions that don't
  pin every bit, `select` patterns with under-specified conditions, etc.).
  Those bugs live below the source language and need a tool that operates on
  ACIR.
- Bugs in the SHA256 circuit itself.
- Bugs in the Noir compiler.

If you want belt-and-suspenders coverage, run an ACIR-level analyzer (e.g.
[Aztec's `aztec compile && aztec profile gates`](https://docs.aztec.network/)
plus an external ACIR linter) in addition to this spec.

---

## Trust base

Believing this proof requires trusting:

1. **The Lean 4 kernel.** ~6k LOC of OCaml/C++. Independently re-checkable.
2. **The four `axiom` declarations** at the top of `Verifier.lean`:
   - `Digest : Type` — exists, opaque.
   - `Digest.instDecidableEq : DecidableEq Digest` — equality on digests is
     decidable. (Trivially true for any concrete byte representation.)
   - `H : Digest → Digest → Digest` — there exists *some* hash function. We
     prove things relative to it.
3. **The translation from Noir to Lean is faithful.** This is by inspection;
   see the `climbStep` ↔ Noir loop body table above. No tooling automates this
   step.

That's it. No `Mathlib`, no `sorry`, no `unsafe`.

---

## Extending the proof

If you change `verifier.nr`, this file likely won't compile any more. To fix:

1. Run `lean lean/Verifier.lean` and read the first error.
2. If it's a `decide` failure on an EL-state-root theorem, you've changed a
   gindex/depth constant. Update `headerBodyRoot`, `bodyExecPayload`,
   `payloadStateRoot`, or rerun the composition mentally and update the
   `matches_noir_constant` target.
3. If it's anywhere in `verify_*`, you've changed loop semantics. Mirror the
   change in `climbStep` or `verify`. The four main theorems are robust to
   leaf/proof representation but not to changes in the climb arithmetic.
4. Re-run `lean lean/Verifier.lean`. Iterate until clean.

---

## Glossary

| Term | Meaning |
|---|---|
| **Merkle proof** | The list of sibling hashes along the path from a leaf to the root. Length = tree depth. |
| **Generalized index (gindex)** | Per the SSZ spec, a 1-based index that uniquely identifies a node in a perfect binary tree. Root = 1; children of node `g` are `2g` (left) and `2g+1` (right); leaves at depth `d` live in `[2^d, 2^(d+1))`. The bit string of `gindex` is the path leaf→root with a leading terminator. |
| **SSZ** | Simple Serialize, the Ethereum 2.0 binary encoding & Merkleization spec. |
| **EL state root** | The Ethereum execution-layer state root, embedded inside a beacon block. The composed gindex `6434` is exactly its position. |
| **Collision-relative soundness** | "If the verifier is unsound, the hash has a collision." A standard cryptographic reduction; our soundness theorem is of this form. |
| **`decide`** | Lean's compiled evaluator for decidable propositions. `decide P = true` ⇔ `P` holds, when `P` has a `Decidable` instance the kernel can run. |
| **Definitional equality** | Equality up to computation/reduction in the kernel. `rfl` proves any definitional equality. |
| **Structural induction** | Induction following the constructors of an inductive type — e.g. proving `P n` for all `n : Nat` by handling `0` and `n+1`. |
| **Tactic** | A small program that builds a proof term. `by ...` is a tactic block; the `...` is a sequence of tactics. |
