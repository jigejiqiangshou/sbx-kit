#!/bin/bash
# SessionStart hook: ensure the model-name-rewrite relay is running.
# Idempotent: kills any stale instance on 127.0.0.1:8765 first.

LOG=/tmp/relay.log
PIDFILE=/tmp/relay.pid
PORT=8765

# Stop any existing relay
if [ -f "$PIDFILE" ]; then
    OLDPID=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$OLDPID" ] && kill -0 "$OLDPID" 2>/dev/null; then
        kill "$OLDPID" 2>/dev/null
    fi
fi
# Also kill anything bound to the port
fuser -k "${PORT}/tcp" 2>/dev/null
sleep 0.3

# Start fresh, fully detached
cd /home/agent
nohup setsid python3 /home/agent/relay.py > "$LOG" 2>&1 < /dev/null &
NEWPID=$!
echo "$NEWPID" > "$PIDFILE"
disown 2>/dev/null

# Brief readiness wait
for i in 1 2 3 4 5 6 7 8 9 10; do
    if (echo > /dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
        break
    fi
    sleep 0.2
done

# Tell the user
echo "[claude-sbx] relay started on 127.0.0.1:${PORT} (pid ${NEWPID})"
exit 0
