#!/bin/bash
set -euo pipefail

# ── travel-runner clean-shell check ─────────────────────────────────────────
# Runs the first database step of the monolith the way a new teammate's Mac
# would: only the tools that the README asks for, an empty home folder, and a
# Python with no extra packages. release.sh runs it before a release is built.
# It would have caught PyJWT: a package that a Python script needed and no README named.
#
# Usage:
#   scripts/clean-shell-check.sh [monolith-dir]
#
# The monolith is the folder given, or TR_MONOLITH_DIR, or fb-travel-monolith
# next to this repo. It must have its packages installed (pnpm install).
#
# The clean shell has:
#   - PATH: a folder with only node (and npm, npx, corepack beside it), pnpm,
#     docker, python3 and, when installed, stripe; then /usr/bin, /bin, /usr/sbin, /sbin.
#   - HOME: an empty folder, so no rc file, ~/.npmrc, docker config or user
#     Python packages count.
#   - python3 runs with -s -S: the standard library only, as on a fresh install.
#   - DOCKER_HOST: the socket of your current docker context, as the runner finds it.
#   - COREPACK_HOME: your corepack cache, with the network off.
#
# It checks:
#   1. node has the major version of .nvmrc or a newer one, and pnpm the major
#      of packageManager.
#   2. python3 and docker answer --version.
#   3. node scripts/db/check-prerequisites.mjs --verify passes. It sends no request.
#   4. Each Python script in scripts/setup and scripts/db (not the tests) imports only
#      the standard library and the modules beside it. The hotel and event-copy steps
#      run these with python3; --verify alone runs no Python. The check reads the
#      imports and runs no script code.
#
# It changes nothing in the monolith and starts no service.
# ────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONOLITH="${1:-${TR_MONOLITH_DIR:-$SCRIPT_DIR/../../fb-travel-monolith}}"

fail() {
    echo "  ✗ clean-shell: $1"
    exit 1
}

[ -f "$MONOLITH/scripts/db/check-prerequisites.mjs" ] \
    || fail "no fb-travel-monolith checkout at $MONOLITH (pass its folder, or set TR_MONOLITH_DIR)"
MONOLITH="$(cd "$MONOLITH" && pwd)"
[ -d "$MONOLITH/node_modules" ] || fail "$MONOLITH has no node_modules. Run pnpm install there first."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/home" "$WORK/tmp"

# ── The README tools, and nothing else ──────────────────────────────────────
# link <tool> <required>: puts the tool of your PATH into the clean PATH.
link() {
    local found
    found="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$found" ] || [ ! -x "$found" ]; then
        [ "$2" = "required" ] || return 0
        fail "$1 is not on your PATH. Install the prerequisites in README.md first."
    fi
    ln -s "$found" "$BIN/$1"
}

link node required
link pnpm required
link docker required
link stripe optional
# npm, npx and corepack come with node: the ones next to it.
NODE_DIR="$(dirname "$(command -v node)")"
for tool in npm npx corepack; do
    if [ -x "$NODE_DIR/$tool" ] && [ ! -e "$BIN/$tool" ]; then
        ln -s "$NODE_DIR/$tool" "$BIN/$tool"
    fi
done

# A fresh Python has only the standard library: -s hides the user packages,
# -S the packages installed into that Python.
PYTHON="$(command -v python3 2>/dev/null || true)"
[ -n "$PYTHON" ] || fail "python3 is not on your PATH. Install the prerequisites in README.md first."
cat > "$BIN/python3" << SHIM
#!/bin/bash
exec "$PYTHON" -s -S "\$@"
SHIM
chmod +x "$BIN/python3"

# The runner gives each step the socket of the current docker context.
DOCKER="${DOCKER_HOST:-}"
if [ -z "$DOCKER" ]; then
    DOCKER="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
fi
DOCKER_ENV=()
[ -z "$DOCKER" ] || DOCKER_ENV=("DOCKER_HOST=$DOCKER")

# clean <command>...: runs a command in the monolith with the clean environment.
clean() {
    (cd "$MONOLITH" && env -i \
        HOME="$WORK/home" TMPDIR="$WORK/tmp" \
        PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        TERM=dumb LANG=en_US.UTF-8 \
        ${DOCKER_ENV[@]+"${DOCKER_ENV[@]}"} \
        COREPACK_HOME="${COREPACK_HOME:-$HOME/.cache/node/corepack}" \
        COREPACK_ENABLE_NETWORK=0 COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
        "$@")
}

# major <version text>: the first number of the last version line ("22", "v22.1.0",
# "10.34.5"). Empty when no line is a version.
major() {
    { printf '%s\n' "$1" | grep -E '^v?[0-9]+(\.[0-9]+)*$' || true; } | tail -1 | sed -E 's/^v?([0-9]+).*/\1/'
}

# ── 1. Versions ─────────────────────────────────────────────────────────────
echo "  clean-shell [1/4] tool versions in $MONOLITH..."
NODE_VERSION="$(clean node --version 2>&1)" || fail "node does not run in a clean shell: $NODE_VERSION"
if [ -f "$MONOLITH/.nvmrc" ]; then
    # The runner and the monolith's engines take this major or a newer one.
    WANT_NODE="$(major "$(tr -d '[:space:]' < "$MONOLITH/.nvmrc")")"
    HAVE_NODE="$(major "$NODE_VERSION")"
    [ -n "$HAVE_NODE" ] && [ -n "$WANT_NODE" ] && [ "$HAVE_NODE" -ge "$WANT_NODE" ] \
        || fail "node is $NODE_VERSION, the monolith's .nvmrc asks for Node $WANT_NODE or newer"
fi
PNPM_VERSION="$(clean pnpm --version 2>&1)" || fail "pnpm does not run in a clean shell: $PNPM_VERSION"
WANT_PNPM="$(sed -nE 's/.*"packageManager": *"pnpm@([0-9]+)\..*/\1/p' "$MONOLITH/package.json" | head -1)"
if [ -n "$WANT_PNPM" ]; then
    [ "$(major "$PNPM_VERSION")" = "$WANT_PNPM" ] \
        || fail "pnpm is $PNPM_VERSION, the monolith's packageManager asks for pnpm $WANT_PNPM"
fi
echo "    ✓ node $NODE_VERSION, pnpm $(major "$PNPM_VERSION").x"

# ── 2. Python and Docker ────────────────────────────────────────────────────
echo "  clean-shell [2/4] python3 and docker..."
PYTHON_VERSION="$(clean python3 --version 2>&1)" \
    || fail "python3 does not run in a clean shell (the Xcode stub?): $PYTHON_VERSION"
DOCKER_VERSION="$(clean docker --version 2>&1)" || fail "docker does not run in a clean shell: $DOCKER_VERSION"
echo "    ✓ $PYTHON_VERSION, $DOCKER_VERSION"

# ── 3. The first database step ──────────────────────────────────────────────
echo "  clean-shell [3/4] check-prerequisites --verify..."
if ! OUTPUT="$(clean node scripts/db/check-prerequisites.mjs --verify 2>&1)"; then
    printf '%s\n' "$OUTPUT" | tail -20 | sed 's/^/      /'
    fail "check-prerequisites failed in a clean shell. A teammate who followed the README hits this too: fix the script or add the tool to both READMEs."
fi
echo "    ✓ check-prerequisites passed"

# ── 4. The Python scripts ───────────────────────────────────────────────────
# The hotel and event-copy steps run scripts/setup/*.py with python3. Each module that
# they import must be in the standard library or beside the script. The check reads
# the imports; it runs no script code, so it sends no request. An import in a
# try/except ImportError is optional and does not count. -B writes no __pycache__.
echo "  clean-shell [4/4] the imports of the Python scripts..."
IMPORT_CHECK='import ast, importlib.util, os, sys
missing = []
for path in sys.argv[1:]:
    here = os.path.dirname(path)
    with open(path, encoding="utf-8") as source:
        tree = ast.parse(source.read(), path)
    optional = set()
    for node in ast.walk(tree):
        if not isinstance(node, ast.Try):
            continue
        caught = []
        for handler in node.handlers:
            kinds = handler.type.elts if isinstance(handler.type, ast.Tuple) else [handler.type]
            caught += [kind.id for kind in kinds if isinstance(kind, ast.Name)]
        if "ImportError" in caught or "ModuleNotFoundError" in caught:
            optional.update(id(sub) for child in node.body for sub in ast.walk(child))
    for node in ast.walk(tree):
        if id(node) in optional:
            continue
        if isinstance(node, ast.Import):
            names = [alias.name for alias in node.names]
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            names = [node.module]
        else:
            continue
        for name in names:
            top = name.split(".")[0]
            if os.path.exists(os.path.join(here, top + ".py")) or os.path.isdir(os.path.join(here, top)):
                continue
            if importlib.util.find_spec(top) is None:
                missing.append("%s:%d: import %s" % (os.path.relpath(path), node.lineno, name))
print("\n".join(missing))
sys.exit(1 if missing else 0)'
PY_SCRIPTS=()
for script in "$MONOLITH"/scripts/setup/*.py "$MONOLITH"/scripts/db/*.py; do
    [ -f "$script" ] || continue
    case "$(basename "$script")" in test_*|*_test.py) continue ;; esac
    PY_SCRIPTS+=("$script")
done
if [ ${#PY_SCRIPTS[@]} -gt 0 ]; then
    if ! OUTPUT="$(clean python3 -B -c "$IMPORT_CHECK" "${PY_SCRIPTS[@]}" 2>&1)"; then
        printf '%s\n' "$OUTPUT" | tail -20 | sed 's/^/      /'
        fail "a Python script imports a module that a python3 with only its standard library does not have. A teammate who followed the README hits this too: use the standard library, or add the package to both READMEs."
    fi
fi
case ${#PY_SCRIPTS[@]} in
    0) echo "    ✓ no Python scripts to check" ;;
    1) echo "    ✓ 1 Python script imports only the standard library" ;;
    *) echo "    ✓ ${#PY_SCRIPTS[@]} Python scripts import only the standard library" ;;
esac

echo "  ✓ clean-shell check passed"
