# Shadow-march phase gate matrix

The march bodies exist in aligned near-copies (mask pre-pass + slow phase + fast
phases, in both `lit_shadow_march.gdshaderinc` and `lit_shadow_cone.gdshaderinc`).
That structure is the measured perf winner and stays; the alignment contract is
enforced BEHAVIORALLY by this matrix, not by text-diffing the bodies. Every cell is a
deterministic `functional_test.tscn` capture (the scene is code-built, so hashes are
stable across sessions); a change to any march body that shifts behavior in any phase
lands as a hash mismatch here.

Phase coverage inside every cell: the skull fragments sit inside its occluder
(grace + receding phases), the open floor runs the steady phase, and each column adds
its slow-phase / pre-pass variant on top. The `ys` cells pin both y-sort directions:
the skull (above the floor's depth line) must LOSE its shadow, the deep wrapped
occluder (below the line) must KEEP its own.

Run one cell:

    godot --path . res://Test/functional_test.tscn -- <args> out=PATH
    md5sum PATH

| cell | args | md5 |
|---|---|---|
| rm_ctl | `algo=raymarch` | 6697de41a1d1ef498d232beec84771fc |
| rm_excl | `algo=raymarch exclude=on` | dd819e6fa3d2cb17556917dbcf2e267d |
| rm_rx | `algo=raymarch rxmask=1` | dd819e6fa3d2cb17556917dbcf2e267d |
| rm_ys | `algo=raymarch ysort=on` | 18c4544ba03aeb7a84c0a2a1237e3e22 |
| cone_ctl | `algo=cone` | 180049855c9c8ab3a450d091e7761c5c |
| cone_excl | `algo=cone exclude=on` | dd819e6fa3d2cb17556917dbcf2e267d |
| cone_rx | `algo=cone rxmask=1` | dd819e6fa3d2cb17556917dbcf2e267d |
| cone_mask | `algo=cone occmask=2 smask=2` | 180049855c9c8ab3a450d091e7761c5c |
| cone_ys | `algo=cone ysort=on` | f1078ca5e9a953799c29bc940d1488c9 |
| cone_ys_mask | `algo=cone ysort=on occmask=2 smask=2` | dd819e6fa3d2cb17556917dbcf2e267d |
| st_ctl | `algo=stochastic` | 30e4094d17ca8066915aef40af25d056 |
| st_excl | `algo=stochastic exclude=on` | dd819e6fa3d2cb17556917dbcf2e267d |
| st_rx | `algo=stochastic rxmask=1` | dd819e6fa3d2cb17556917dbcf2e267d |
| st_ys | `algo=stochastic ysort=on` | 9605deb6f2a26592ed860ac0e2735c98 |

Expected class collapses (these ARE the pins, not coverage gaps):

- Every `excl` / `rx` cell converges to `dd81...` - the no-skull-shadow image. The
  algorithms only differ inside the shadow, so a correct exclusion erases the
  difference; a broken exclusion resurfaces the per-algorithm control hash instead.
- `cone_mask` equals `cone_ctl` (`1800...`): occluder mask 2 + light mask 2 still
  match, so the shadow must survive the whole mask pre-pass machinery unchanged.
- `cone_ys_mask` equals `dd81...`: the deep occluder and floor strip are mask 1
  against a mask-2 light, so gx removes them, and y-sort exempts the skull - a
  break in either direction changes the hash.

Baselined 2026-08-01 (plan 4 step 7) on RX 7900 XTX at 1920x1080, two full passes
byte-identical. Hashes are machine-local: compare pre/post on one machine rather
than trusting absolutes across hardware. Re-baseline any cell only with an intended
visual change, and note it here. The post-processing chain has its own hash gate:
`Test/gate_post_chain.tscn` (baselines in its script header).

Adding a march axis or a new algorithm: add its column cells here, following the
existing arg conventions in `functional_test.gd`.
