# Releasing Travel Runner

A release reaches the team in two steps. `./release.sh <version>` publishes to the
canary channel only. `./release.sh --promote <version>` gives it to everyone.

## Before the first release from a Mac

- The Developer ID Application certificate is in the keychain.
- The notary credentials are stored: `xcrun notarytool store-credentials "travel-runner-notarize"`.
- The Sparkle EdDSA private key is in the keychain (the script compares it with the key in the app).
- `gh` is logged in as an account that can release to the repository
  (`gh auth switch --user <owner>`).

## 1. Publish to the canary channel

```bash
./release.sh 0.14.0
```

The script, in order:

1. Checks that the release can finish: signing identity, notary access, GitHub access,
   a clean tree whose commit is on the remote, a version number that is not used, and
   that the latest release on GitHub is a standard release.
2. Runs `swift test`, then `scripts/clean-shell-check.sh` on the monolith (see below).
3. Builds, packages and signs the app.
4. Runs `scripts/smoke.sh` on the signed app (see below). A failure stops the release
   before the notarization, so the version number is still free.
5. Notarizes and staples.
6. Publishes `v0.14.0` as a **prerelease** and puts its appcast on the fixed release
   `canary-appcast`.

GitHub never marks a prerelease as the latest release, and the installed apps read the
appcast of the latest release. So no teammate gets the new version yet.

### Release notes

Sparkle's update window shows the notes of the appcast item. By default they are the
subjects of the commits since the last full release. To write them by hand, give a
file with one change per line:

```bash
RELEASE_NOTES=notes.txt ./release.sh 0.14.0
```

The appcast item also lists the versions of all full releases. An installed copy that
has not updated for 7 days counts from it how many versions behind it is, and says so
in a banner.

### Updates on the teammates' Macs

The app downloads an update in the background and shows "Update 0.14.0 ready — Restart
to install". It installs the update by itself only when the stack is stopped, the window
is closed, and no database step, fix or reconfigure runs. Otherwise it installs at the
next quit, or when the teammate clicks the pill.

Quit your own installed Travel Runner before you run the script: the smoke test starts
the new build, and only one copy of the app runs at a time.

### The canary channel

A copy on the canary channel reads `canary-appcast` and gets every release at once:

```bash
defaults write ai.fastbreak.travel-runner updateChannel canary   # join
defaults delete ai.fastbreak.travel-runner updateChannel         # leave
```

Quit and reopen the app after the change. The canary is the person who released, plus
anyone who agreed to it. Use the release for at least one working day: a start from a
stopped stack, a database reset, and a quit.

## 2. Promote

```bash
./release.sh --promote 0.14.0
```

The script checks that the release has `appcast.xml` and the zip, makes it a full
release, marks it as the latest, and reads back that GitHub agrees. Every installed
copy sees it at its next update check.

After the promotion of a release that carries a new compatibility check, the monolith
may name it in `scripts/db/manifest.json` (`"runner": { "minVersion": "…" }`). Never
before: an installed copy that is older than the minimum refuses every reset.

## Take a release back

```bash
./release.sh --pull 0.14.0
```

The release becomes a prerelease again, the full release before it becomes the latest,
and the canary feed goes back to that release too. Copies that have not updated yet
do not get the pulled version.

A copy that already installed the pulled version keeps it: Sparkle never installs an
older version. To move those copies, release the older source under a new number:

```bash
./release.sh --rollback-to v0.13.5 0.14.1
./release.sh --promote 0.14.1
```

`--rollback-to` builds the source of the tag in a separate worktree, with the new
version number, and publishes it like any release (canary first). A tag older than
0.14.0 has no smoke-test seams and cannot pass the smoke test; for such a tag only:

```bash
SKIP_SMOKE=1 ./release.sh --rollback-to v0.13.5 0.14.1
```

## A draft

```bash
./release.sh 0.14.0 --draft
```

A draft runs the whole pipeline and creates a release that nobody sees, and it does
not touch a feed. `SKIP_TESTS=1` works with `--draft` only. To release a draft, publish
it on GitHub with "Set as a pre-release" ticked, then run `--promote`. A draft uses up
its version number.

## The smoke test

```bash
scripts/smoke.sh TravelRunner.app
```

It launches the app the way a new teammate's Mac would: an empty home folder, the
PATH `/usr/bin:/bin`, no config. It checks that the control API answers with the
version of the bundle and `"configured": false`, and that `/api/preflight` answers with
a result for Node and does not hang. Then it launches the app again with a config for
a copy of `Tests/Fixtures/mini-monorepo` and checks that the config loads and that
nothing was started.

The launch uses three seams, and `CFFIXED_USER_HOME` for everything under `~`, so the
real config, logs, issues and preferences are not touched:

| Variable | Meaning |
|---|---|
| `TRAVEL_RUNNER_CONFIG_DIR` | The folder of `services.json`, in place of `~/.config/travel-runner`. |
| `TRAVEL_RUNNER_CONTROL_PORT` | The port of the control API, in place of 19900 (19901 for the hackathon app). |
| `TRAVEL_RUNNER_SMOKE=1` | A launch that nobody watches: no alert, no permission prompt, no window. |

The Node result depends on the Mac: with Node in `/opt/homebrew` or `/usr/local` the
check passes, and on a Mac without Node it fails. Both are a pass for the smoke test;
a check with no result, or no answer, is not.

It runs on a dev build too (`./build.sh && scripts/smoke.sh TravelRunner.app`).

## The clean-shell check

```bash
scripts/clean-shell-check.sh [monolith-dir]
```

It runs the first database step of the monolith (`check-prerequisites.mjs --verify`,
which sends no request) the way a teammate's Mac that followed the README would: a PATH
with only node (and npm, npx, corepack), pnpm, docker, python3 and stripe (when installed), an empty
home folder, and a python3 that has only its standard library. It also checks that
node is at least the major of `.nvmrc` and that pnpm has the major of `packageManager`.
`--verify` runs no Python, so the check then reads the imports of each Python script in
`scripts/setup` and `scripts/db` (not the tests) with that python3: each module must be
in the standard library or beside the script. It runs no script code. A step that needs
a tool or a Python package that no README names fails here. The PyJWT break of the
hotel step (`import jwt` in `remote_supabase.py`) would have failed here.

The monolith is the folder given, or `TR_MONOLITH_DIR`, or `fb-travel-monolith` next to
this repo (`fb-travel-monolith-hackathon` for `FLAVOR=hackathon`). Run `pnpm install`
there first. Docker must run: the check uses the socket of your current docker context.
When the check fails because a step needs a new tool, add the tool to the install steps
of both READMEs, or remove the need from the script.

`release.sh` runs the check only on the scripts that teammates get. Before the tests it
fetches the monolith and stops unless its HEAD is `origin/dev` (`origin/main` for
`FLAVOR=hackathon`; `TR_MONOLITH_BRANCH` overrides) with no local change. It prints the
branch and commit that it checks.

`SKIP_TESTS=1` skips it with the tests, for a `--draft` only.

## Travel Runner Hackathon

```bash
FLAVOR=hackathon ./release.sh 1.4.0
```

The hackathon app has one feed (the fixed release `hackathon-appcast`) and no canary,
so its release is live when the script ends, and `--promote` refuses it. `--pull` and
`--rollback-to` work the same way. A hackathon release is never the latest release;
the script checks this before it publishes and again after.

The two apps still share one Sparkle key. A separate key for the hackathon app is an
open decision.

## If something goes wrong

| What you see | What to do |
|---|---|
| "another copy of this app runs" from the smoke test | Quit Travel Runner (menu bar icon → Quit) and run the script again. |
| The notarization times out | Run the script again with the same version: nothing was published. |
| "GitHub marks … as the latest release" | Open the releases page and set the newest promoted `v…` release as the latest. Installed apps read their updates from it. |
| `gh` cannot release | `gh auth switch --user <owner>`. |
| "The monolith at … is on …, not origin/dev" | Pull dev in that checkout, or set `TR_MONOLITH_DIR` to a checkout of dev. |
| "The clean-shell check failed" | Read the lines above it. "no node_modules": run `pnpm install` in the monolith. A failed check-prerequisites or a Python import: a teammate's first Start fails the same way; fix the monolith script or the READMEs first. |
