#!/usr/bin/env bash
#
# restore_archived_buckets.sh
#
# Rehydrate frozen / archived Splunk buckets into a new searchable index.
#
# Instead of hard-coded paths, this prompts the operator for:
#   * the remote bucket source path
#   * the local staging (temp) location
#   * the index tag prefix to strip from bucket names
#   * the new index name (always created as  archived_<your input>)
#
# The long-running loops (rsync, rebuild, recover-metadata) are launched in
# detached tmux sessions so they run to completion in the background rather
# than you babysitting `top`. The script waits for each phase to finish and
# prompts before moving on.

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# prompt VAR "Question" ["default"]   -> reads input into VAR, re-asks if empty
prompt() {
    local __var="$1" __msg="$2" __def="${3:-}" __ans=""
    if [[ -n "$__def" ]]; then
        read -rp "$__msg [$__def]: " __ans
        __ans="${__ans:-$__def}"
    else
        while [[ -z "$__ans" ]]; do
            read -rp "$__msg: " __ans
        done
    fi
    printf -v "$__var" '%s' "$__ans"
}

# run_in_tmux SESSION "command string"  -> launch a detached tmux session
run_in_tmux() {
    local session="$1" cmd="$2"
    tmux has-session -t "$session" 2>/dev/null && tmux kill-session -t "$session"
    echo ">> launching tmux session '$session'"
    # Session stays open after the work finishes so you can inspect the log.
    tmux new-session -d -s "$session" \
        "bash -lc '$cmd; rc=\$?; echo; echo \"[$session] finished rc=\$rc\"; touch \"$DONE_DIR/$session.done\"; exec bash'"
}

# wait_for_sessions PREFIX  -> block until every $session.done marker exists
wait_for_sessions() {
    local -n _sessions="$1"
    echo ">> waiting for ${#_sessions[@]} tmux session(s) to finish..."
    echo "   (attach to watch:  tmux attach -t <name> )"
    local pending=1
    while (( pending )); do
        pending=0
        for s in "${_sessions[@]}"; do
            if [[ ! -f "$DONE_DIR/$s.done" ]]; then
                pending=1
                echo "   still running: $s"
            fi
        done
        (( pending )) && sleep 10
    done
    echo ">> all sessions complete."
}

# continue_or_abort "message"  -> ask y/N, exit unless confirmed
continue_or_abort() {
    local ans
    read -rp "$1 Continue? [y/N]: " ans
    case "$ans" in
        y|Y|yes|YES) return 0 ;;
        *) echo "Aborting."; exit 1 ;;
    esac
}

command -v tmux >/dev/null || { echo "tmux is required but not installed."; exit 1; }
command -v rsync >/dev/null || { echo "rsync not found — install it (e.g. apt install rsync)"; exit 1; }

DONE_DIR="$(mktemp -d /tmp/restore_archived.XXXXXX)"
trap 'rm -rf "$DONE_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1. Gather input
# ---------------------------------------------------------------------------
echo "=== Splunk archived-bucket restore ==="
echo

prompt REMOTE_SRC   "Remote bucket source (host:path, e.g. splunk-remote:ssbX/ant_syslog/cold46/DEFAB46186_db_*)"
prompt STAGING      "Local staging / temp directory" "/frozen/_bucket_temp"
prompt TAG          "Index tag prefix to strip from bucket names (e.g. DEFAB46186)"
prompt SPLUNK_HOME  "SPLUNK_HOME" "/opt/splunk"
prompt DEST_DB      "Destination index db path the buckets land in (e.g. /ant/rsskb6/ant_syslog/cold46)"

prompt INDEX_SUFFIX "New index name:  archived_"
INDEX="archived_${INDEX_SUFFIX}"

SPLUNK="$SPLUNK_HOME/bin/splunk"

echo
echo "----------------------------------------------------------------"
echo "  Source        : $REMOTE_SRC"
echo "  Staging        : $STAGING"
echo "  Tag to strip  : $TAG"
echo "  Splunk        : $SPLUNK"
echo "  Dest db path  : $DEST_DB"
echo "  New index     : $INDEX"
echo "----------------------------------------------------------------"
continue_or_abort "Proceed with these settings?"

mkdir -p "$STAGING"

# ---------------------------------------------------------------------------
# 2. Create the new index in Splunk
# ---------------------------------------------------------------------------
echo ">> creating index '$INDEX' in Splunk"
# Pin the index to the destination path. Buckets land in $DEST_DB (the cold
# path); home/thawed are derived as siblings per Splunk's db/thaweddb convention.
DEST_PARENT="$(dirname "$DEST_DB")"
HOME_PATH="$DEST_PARENT/db"
THAWED_PATH="$DEST_PARENT/thaweddb"
"$SPLUNK" add index "$INDEX" \
    -homePath "$HOME_PATH" \
    -coldPath "$DEST_DB" \
    -thawedPath "$THAWED_PATH"
continue_or_abort "Index '$INDEX' created (cold=$DEST_DB)."

# ---------------------------------------------------------------------------
# 3. Pull the frozen buckets down into staging (tmux)
# ---------------------------------------------------------------------------
rsync_sessions=( "rsync_$INDEX" )
run_in_tmux "rsync_$INDEX" \
    "rsync -avz --progress '$REMOTE_SRC' '$STAGING/'"
wait_for_sessions rsync_sessions
continue_or_abort "rsync into staging complete."

# ---------------------------------------------------------------------------
# 4. Rename buckets in staging: drop the GUID-style remote suffix and the tag
# ---------------------------------------------------------------------------
echo ">> renaming buckets in $STAGING"
pushd "$STAGING" >/dev/null

# Strip the "<TAG>_" prefix from each bucket directory.
for bucket in ${TAG}_*; do
    [[ -e "$bucket" ]] || continue
    newname="${bucket#${TAG}_}"
    echo "   $bucket -> $newname"
    mv "$bucket" "$newname"
done
popd >/dev/null
continue_or_abort "Bucket renaming complete."

# ---------------------------------------------------------------------------
# 5. Move buckets into the destination index db path
# ---------------------------------------------------------------------------
echo ">> moving buckets into $DEST_DB"
mkdir -p "$DEST_DB"
mv "$STAGING"/db_* "$DEST_DB"/ 2>/dev/null || true
continue_or_abort "Buckets moved into destination index."

# ---------------------------------------------------------------------------
# 6. Rebuild every bucket (one tmux session per bucket so they run in parallel)
# ---------------------------------------------------------------------------
rebuild_sessions=()
i=0
for bucket in "$DEST_DB"/db_*; do
    [[ -e "$bucket" ]] || continue
    s="rebuild_${INDEX}_$i"
    rebuild_sessions+=( "$s" )
    run_in_tmux "$s" "'$SPLUNK' rebuild '$bucket'"
    ((i++))
done
wait_for_sessions rebuild_sessions
continue_or_abort "All bucket rebuilds complete."

# ---------------------------------------------------------------------------
# 7. Recover bucket metadata (tmux)
# ---------------------------------------------------------------------------
recover_sessions=()
i=0
for bucket in "$DEST_DB"/db_*; do
    [[ -e "$bucket" ]] || continue
    s="recover_${INDEX}_$i"
    recover_sessions+=( "$s" )
    run_in_tmux "$s" \
        "'$SPLUNK' cmd recover-metadata '$bucket' --fixup-bucket-metadata-after-delete"
    ((i++))
done
wait_for_sessions recover_sessions
continue_or_abort "Metadata recovery complete."

# ---------------------------------------------------------------------------
# 8. Restart Splunk so the new index is searchable
# ---------------------------------------------------------------------------
echo ">> restarting Splunk"
"$SPLUNK" restart

echo
echo "================================================================"
echo " Done. Index '$INDEX' should now be searchable."
echo " Hand the URL + admin creds to whoever needs it and let them at it."
echo "================================================================"

# Final prompt instead of just stopping.
continue_or_abort "Restore finished."
echo "Continuing."
