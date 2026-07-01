#!/bin/sh
# Wellmade devcontainer initializer.
#
#   curl -fsSL https://raw.githubusercontent.com/wellmade-oss/devcontainers/main/init.sh | sh
#
# Scaffolds .devcontainer/devcontainer.json in the current project folder.
# Picks an image from the catalog, names the container after the folder,
# and writes the canonical template with the chosen tag.
#
# Zero dependencies beyond curl + a POSIX sh. No jq, no node, no wm needed —
# this is the pre-tooling bootstrap. The logic is written to migrate cleanly
# into `wm devcontainer` later; the curl entrypoint stays as the no-CLI path.
#
# Non-interactive (no TTY, e.g. CI): defaults to the workbench image and the
# folder-basename name, writes the file, and exits without prompting.

set -eu

# --- config ----------------------------------------------------------------
REPO_RAW="https://raw.githubusercontent.com/wellmade-oss/devcontainers/main"
DEFAULT_IMAGE="workbench"   # the "reach for unless you have a reason not to" tier
TAG="latest"                # what we pin generated files to (see note in output)

# --- helpers ---------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
err()  { printf 'error: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# Read from the real terminal, not the piped-in script on stdin. Falls back to
# the supplied default when there's no TTY (CI / non-interactive pipe).
#   prompt_default VAR "question" "default"
prompt_default() {
  _var=$1 _msg=$2 _def=$3
  if [ -r /dev/tty ] && [ -t 1 ]; then
    printf '%s [%s] ' "$_msg" "$_def" > /dev/tty
    read -r _ans < /dev/tty || _ans=""
  else
    _ans=""
  fi
  [ -n "$_ans" ] || _ans=$_def
  eval "$_var=\$_ans"
}

command -v curl >/dev/null 2>&1 || die "curl is required but not found on PATH."

# --- target dir + default name ---------------------------------------------
TARGET_DIR=$PWD
FOLDER_NAME=$(basename "$TARGET_DIR")

say "Wellmade devcontainer initializer"
say "  target: $TARGET_DIR"
say ""

# --- pick the image --------------------------------------------------------
# Default is workbench; plain Enter accepts it.
if [ -r /dev/tty ] && [ -t 1 ]; then
  {
    printf 'Which image?\n'
    printf '  1) workbench  (Node + Python + Rust + cloud)  [default]\n'
    printf '  2) core       (agent-ready base)\n'
  } > /dev/tty
fi
prompt_default IMAGE_CHOICE "  choose 1 or 2" "1"
case "$IMAGE_CHOICE" in
  1|workbench) IMAGE="workbench" ;;
  2|core)      IMAGE="core" ;;
  *)           say "  unrecognized choice '$IMAGE_CHOICE' — using $DEFAULT_IMAGE"
               IMAGE="$DEFAULT_IMAGE" ;;
esac

# --- name the container ----------------------------------------------------
prompt_default CONTAINER_NAME "Container name" "$FOLDER_NAME"

# --- fetch the canonical template ------------------------------------------
SRC_URL="$REPO_RAW/images/$IMAGE/devcontainer.json"
say ""
say "Fetching $IMAGE template…"
TEMPLATE=$(curl -fsSL "$SRC_URL") \
  || die "could not fetch $SRC_URL (network? image name?)"

# --- patch: name, tag, and (workbench) comment out the docker socket -------
# The committed templates have a known shape:
#   "name": "Wellmade <image>",
#   "image": "ghcr.io/wellmade-oss/dc-<image>:v1",
# We rewrite the name to the chosen one, flip the :v1 tag to our generated
# tag, and add a // note that they can pin :v1 for a stable image instead.
#
# Done with one awk pass — portable across GNU (Debian) and BSD (macOS) awk,
# and no jq dependency on a bare host. sed is avoided here because its `\s`
# class and `\n`-in-replacement behavior differ between GNU and BSD; awk's
# line-matching + multi-line print is identical on both.
#
# Edits, keyed off the committed template's known lines:
#   - "name":  → rewritten to the chosen container name
#   - dc-<img>:v1 → dc-<img>:<tag>, with a // pin note inserted above it
#   - (workbench) the live docker.sock bind → commented out, opt-in
# Single portable awk pass. The committed workbench template deliberately
# keeps the docker.sock bind NOT-last in `mounts` (cache mount follows it), so
# commenting the bind out leaves no dangling trailing comma — no buffering or
# look-back needed.
OUT=$(printf '%s\n' "$TEMPLATE" | awk \
  -v name="$CONTAINER_NAME" -v image="$IMAGE" -v tag="$TAG" '
  function indent_of(s) { sub(/[^ \t].*/, "", s); return s }

  # "name": "..." → chosen name (match the key, replace the whole value)
  $0 ~ /^[ \t]*"name":/ {
    print indent_of($0) "\"name\": \"" name "\","
    next
  }

  # image line: pin note + retag :v1 → :tag
  $0 ~ ("\"image\": \"ghcr.io/wellmade-oss/dc-" image ":v1\",") {
    print indent_of($0) "// Pinned to :" tag " (newest build). Switch to :v1 for a stable major pin."
    line = $0
    sub(":v1\",", ":" tag "\",", line)
    print line
    next
  }

  # workbench host docker socket bind → commented out (opt-in for `act`)
  $0 ~ /"source=\/var\/run\/docker\.sock/ {
    ind = indent_of($0)
    print ind "// Uncomment to run `act` / use host Docker (NOT Docker-in-Docker):"
    body = $0
    sub(/^[ \t]*/, "", body)
    print ind "// " body
    next
  }

  { print }
')

# --- write -----------------------------------------------------------------
DEST_DIR="$TARGET_DIR/.devcontainer"
DEST="$DEST_DIR/devcontainer.json"

if [ -e "$DEST" ]; then
  say ""
  say "A devcontainer already exists at $DEST"
  prompt_default OVERWRITE "  overwrite it? (y/N)" "N"
  case "$OVERWRITE" in
    y|Y|yes|YES) : ;;
    *) die "aborted — existing file left untouched." ;;
  esac
fi

mkdir -p "$DEST_DIR"
printf '%s\n' "$OUT" > "$DEST"

# --- done ------------------------------------------------------------------
say ""
say "✓ Wrote $DEST"
say "  image: ghcr.io/wellmade-oss/dc-$IMAGE:$TAG"
say "  name:  $CONTAINER_NAME"
say ""
say "Next: open this folder in VS Code and run “Dev Containers: Reopen in Container”."
if [ "$IMAGE" = "workbench" ]; then
  say "Note: the host Docker-socket mount (for \`act\`) is commented out — uncomment it in"
  say "      $DEST if you need it."
fi
