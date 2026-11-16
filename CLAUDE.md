# Rules for unattended sessions

This repo is being rewritten from Zig to Rust on branch `master`. Each session
is started with "proceed" by `tools/loop.sh`. Nobody is there to answer
questions.

1. Read `docs/PLAN.md`. Do exactly the **next unchecked step**, and only that
   step (one step per session). Keep it small and follow the design spec.
2. Before each commit, run `cargo fmt`, `cargo test --release` and
   `cargo clippy --release --all-targets -- -D warnings`. All must pass.
3. Tick the step (`- [x]`) in PLAN.md and add brief notes under "Notes".
4. Make small, logical commits with clear messages. Push to `origin master`
   after the step (`git push origin master`).
5. Decide technical questions yourself. Record each decision in one line
   under "Decisions" in PLAN.md.
6. If every step is done, or something truly blocks progress, write the
   reason into `STOP` in the repo root (it is gitignored) and end the
   session without committing.

Work only on `master`; never touch other branches. Never force-push or
rewrite history. Never install Docker. Never write secrets. Never use `target-cpu=native`.
