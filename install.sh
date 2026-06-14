#!/bin/bash
# install.sh - Deploy the sbx Claude relay kit into /home/agent.
#
# Run inside a Docker Sandbox after `git clone` of the sbx-kit repo:
#
#     git clone https://github.com/jigejiqiangshou/sbx-kit.git /tmp/sbx-kit
#     bash /tmp/sbx-kit/install.sh
#
# Or, if you cloned to a different path:
#
#     bash /path/to/sbx-kit/install.sh [/path/to/sbx-kit]
#
# What it does:
#   1. Verifies the 3 kit files exist in SRC (default: current dir)
#   2. Copies them to /home/agent/ and /home/agent/.claude/
#   3. Marks start-relay.sh executable
#   4. Boots the relay (idempotent: kills any old relay first)
#
# Designed to be robust in minimal container images:
#   * No dependency on GNU `install` (uses cp + chmod)
#   * Falls back to /root if /home/agent is missing
#   * Creates parent directories as needed
#   * Surfaces per-step errors so partial state is visible

set -u  # NOTE: not -e, so we surface per-step errors

SRC="${1:-.}"
KIT_USER="agent"
KIT_HOME="/home/${KIT_USER}"

# 1. Sanity check
echo "[install.sh] source dir: $SRC"
for f in relay.py start-relay.sh settings.json; do
    if [ ! -f "$SRC/$f" ]; then
        echo "[install.sh] ERROR: missing $f in $SRC" >&2
        exit 1
    fi
done

# 2. Pick a writable home. Most Docker Sandbox claude images put the user
#    in /home/agent, but a custom image might use /root.
if [ ! -d "$KIT_HOME" ]; then
    if [ -d "/root" ] && [ -w "/root" ]; then
        KIT_HOME="/root"
        echo "[install.sh] /home/agent missing, falling back to $KIT_HOME"
    else
        echo "[install.sh] ERROR: neither $KIT_HOME nor /root is writable" >&2
        exit 1
    fi
fi
echo "[install.sh] deploy target: $KIT_HOME"

# 3. Ensure parent dirs
mkdir -p "$KIT_HOME" "$KIT_HOME/.claude" || {
    echo "[install.sh] ERROR: cannot create $KIT_HOME or $KIT_HOME/.claude" >&2
    exit 1
}

# 4. Copy files
ok=1
cp -f "$SRC/relay.py"        "$KIT_HOME/relay.py"              || { echo "[install.sh] ERROR: copy relay.py" >&2; ok=0; }
cp -f "$SRC/start-relay.sh"  "$KIT_HOME/start-relay.sh"        || { echo "[install.sh] ERROR: copy start-relay.sh" >&2; ok=0; }
cp -f "$SRC/settings.json"   "$KIT_HOME/.claude/settings.json"  || { echo "[install.sh] ERROR: copy settings.json" >&2; ok=0; }

if [ "$ok" -ne 1 ]; then
    echo "[install.sh] one or more file copies failed" >&2
    exit 1
fi

# 5. Mark start-relay.sh executable
chmod +x "$KIT_HOME/start-relay.sh" || echo "[install.sh] WARN: chmod failed (continuing)" >&2

# 6. Boot the relay. start-relay.sh is idempotent and self-detaches,
#    so this is safe to run multiple times.
"$KIT_HOME/start-relay.sh" || echo "[install.sh] WARN: start-relay.sh returned non-zero (SessionStart hook will retry)" >&2

echo "[install.sh] kit deployed to $KIT_HOME"
exit 0
