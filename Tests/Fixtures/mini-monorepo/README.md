# mini-monorepo

The smallest folder that Travel Runner takes for the fb-travel monorepo
(`RepoDetector.isMonorepo`). `scripts/smoke.sh` copies it to a temporary folder
and launches the app against the copy. Nothing in it runs: the smoke test never
starts a service or a database step.
