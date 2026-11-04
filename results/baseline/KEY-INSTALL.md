# SSH key installation record (phase 1C)

Date: 2026-11-04

- Baseline snapshots in this directory were captured **before** any change,
  using the pre-existing stage-0 access (`tunnel-iran` / `tunnel-germany`
  aliases, key `tunnel-lab_ed25519`).
- A fresh dedicated key was generated locally:
  `~/.ssh/quantum-lab_ed25519` (ed25519, comment `quantum-lab-phase1c`,
  no passphrase — lab automation key).
- Its public half was appended to `/root/.ssh/authorized_keys` on both lab
  servers (guarded append: skipped if the line already exists).
- New `~/.ssh/config` aliases used by all scripts: `qlab-iran`,
  `qlab-germany` (ProxyJump via `qlab-iran`), `IdentitiesOnly yes`.

## To undo

Remove the line containing `quantum-lab-phase1c` from
`/root/.ssh/authorized_keys` on both servers, and delete the local key
`~/.ssh/quantum-lab_ed25519{,.pub}` plus the two `qlab-*` config blocks.
The `tunnel-lab-stage0` access was left untouched.

No password auth was used or stored anywhere; the servers' sshd configs were
not modified (baseline `03-sshd-config.txt` proves the pre-touch state).
