#!/bin/bash

# Pulls the latest version of this repository, then adds anything new from the
# example files to your own config files without changing what is already there.
#
# Everything lives in functions and main is called from the very last line, as
# bash reads scripts while running them and the pull can replace this file.

AUTO_YES=0
AUTO_UP=0
STASHED=0
STASH_FAILED=0
TMP_FILE=""
ADDED_FILE=""
declare -A BACKED_UP

usage() {
    cat <<EOF
Usage: $(basename "$0") [-y] [-f]

  -y    Don't ask: stash local changes, comment out removed services
  -f    Run "docker compose up -d" before finishing
EOF
}

warn() {
    echo "WARNING: $*" >&2
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Restore stashed changes, also used on exit so a failure can't leave them behind
unstash() {
    [ "$STASHED" -eq 1 ] || return 0
    STASHED=0
    echo "Restoring stashed changes..."
    if ! git stash pop --quiet; then
        STASH_FAILED=1
        warn "Could not restore your stashed changes cleanly, they are still in the stash."
        warn "Fix any conflicts shown by \"git status\", then run \"git stash drop\" when finished."
    fi
}

on_exit() {
    local code=$?
    [ -n "$TMP_FILE" ] && rm -f "$TMP_FILE"
    [ -n "$ADDED_FILE" ] && rm -f "$ADDED_FILE"
    unstash
    [ "$STASH_FAILED" -eq 1 ] && [ "$code" -eq 0 ] && code=1
    exit "$code"
}

stash_changes() {
    git stash push --quiet --include-untracked --message "update.sh $(date '+%F %T')" || die "Could not stash your changes."
    STASHED=1
    echo "Stashed your local changes."
}

reset_changes() {
    local answer
    read -r -p "This permanently discards your local changes, are you sure? [y/N] " answer || answer=""
    case "$answer" in
    y | Y) git reset --quiet --hard HEAD || die "Could not reset your changes." ;;
    *)
        echo "Cancelled, nothing has been changed."
        exit 0
        ;;
    esac
}

ask_local_changes() {
    local answer
    if [ "$AUTO_YES" -eq 1 ]; then
        stash_changes
        return
    fi
    while true; do
        read -r -p "[s]tash, [r]eset, or [c]ancel? " answer || answer="c"
        case "$answer" in
        s | S)
            stash_changes
            return
            ;;
        r | R)
            reset_changes
            return
            ;;
        c | C | "")
            echo "Cancelled, nothing has been changed."
            exit 0
            ;;
        esac
    done
}

# Line endings and whitespace often change just by editing over a network share
revert_whitespace_changes() {
    local file files
    mapfile -d '' -t files < <(git diff HEAD --name-only -z --diff-filter=M)
    for file in "${files[@]}"; do
        if git diff HEAD --quiet --ignore-all-space --ignore-blank-lines --ignore-cr-at-eol -- "$file"; then
            git checkout --quiet HEAD -- "$file" && echo "Reverted whitespace changes: $file"
        fi
    done
}

# Anything here that a stash wouldn't fix needs a person to sort it out
check_git_state() {
    local path behind ahead tracked blocking

    for path in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
        [ ! -e "$(git rev-parse --git-path "$path")" ] || die "A git operation is in progress ($path), finish or abort it first."
    done
    git symbolic-ref --quiet HEAD >/dev/null || die "Not on a branch (detached HEAD), check out a branch first."
    git rev-parse --verify --quiet "@{upstream}" >/dev/null || die "The current branch has no upstream to pull from."
    git fetch --quiet || die "Could not fetch from the remote."

    behind=$(git rev-list --count "HEAD..@{upstream}")
    ahead=$(git rev-list --count "@{upstream}..HEAD")
    if [ "$behind" -eq 0 ]; then
        echo "Already up to date."
        return
    fi
    [ "$ahead" -eq 0 ] || die "This branch has diverged from its upstream ($ahead local, $behind remote commits), merge or rebase it first."

    revert_whitespace_changes
    tracked=$(git status --porcelain --untracked-files=no)
    blocking=$(git ls-files --others --exclude-standard | grep -Fxf <(git diff --name-only HEAD "@{upstream}"))
    [ -n "$tracked$blocking" ] || return

    echo "You have local changes:"
    [ -z "$tracked" ] || echo "$tracked"
    [ -z "$blocking" ] || echo "$blocking" | sed 's/^/?? /'
    ask_local_changes

    # A reset doesn't touch untracked files, and they would still block the pull
    if [ "$STASHED" -eq 0 ] && [ -n "$blocking" ]; then
        die "Untracked files would be overwritten by the pull, move them first."
    fi
}

backup_once() {
    if [ -z "${BACKED_UP[$1]:-}" ]; then
        cp -p "$1" "$1.bak" || die "Could not back up $1."
        BACKED_UP[$1]=1
    fi
}

# Replace a file from the output of the given command, keeping its permissions
rewrite() {
    local file=$1
    shift
    TMP_FILE=$(mktemp "$file.XXXXXX") || die "Could not create a temporary file for $file."
    cp -p "$file" "$TMP_FILE" || die "Could not copy $file."
    "$@" >"$TMP_FILE" || die "Could not update $file."
    backup_once "$file"
    mv "$TMP_FILE" "$file" || die "Could not replace $file."
    TMP_FILE=""
}

awk_merge_env() {
    awk -v BINMODE=3 -v user="$1" -v src="$2" -v added="$ADDED_FILE" '
    function clean(s) { sub(/\r$/, "", s); return s }
    function keyof(s) {
        sub(/^[ \t]*(#[# \t]*)?(export[ \t]+)?/, "", s)
        if (s !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return ""
        sub(/=.*/, "", s)
        return s
    }
    function is_pure(s) { return s ~ /^###+[ \t]*$/ }
    function titleof(s) {
        if (s !~ /^###+[ \t]+.*[^# \t][ \t]+###+[ \t]*$/) return ""
        sub(/^#+[ \t]+/, "", s)
        sub(/[ \t]+#+[ \t]*$/, "", s)
        return s
    }
    function is_note(s) { return s ~ /^[ \t]*#/ && keyof(s) == "" && titleof(s) == "" && !is_pure(s) }
    function add(anchor, line) { ins[anchor] = ins[anchor] line "\n" }
    function report(k) {
        if (!(k in reported)) { reported[k] = 1; print k > added }
    }
    # Where to put new lines when nothing earlier in the section exists
    function after_header(h, j) {
        j = h
        if (is_pure(u[j + 1])) j++
        h = j
        while (j < nu && is_note(u[j + 1])) j++
        if (j > h && keyof(u[j + 1]) != "") return h
        if (u[j + 1] ~ /^[ \t]*$/ && j < nu) j++
        return j
    }
    # The last line belonging to a section, not counting trailing blanks
    function section_end(h, j) {
        j = h + 1
        while (j <= nu && titleof(u[j]) == "") j++
        j--
        while (j > h && (u[j] ~ /^[ \t]*$/ || is_pure(u[j]))) j--
        return j
    }
    BEGIN {
        while ((getline raw < user) > 0) {
            if (nu == 0 && raw ~ /\r$/) eol = "\r"
            nu++
            uraw[nu] = raw
            u[nu] = clean(raw)
            k = keyof(u[nu])
            if (k != "") ukey[k] = nu
            t = titleof(u[nu])
            if (t != "") utitle[t] = nu
        }
        ns = 0
        secs = 0
        sec_start[0] = 1
        while ((getline raw < src) > 0) {
            ns++
            s[ns] = clean(raw)
            t = titleof(s[ns])
            if (t != "") {
                secs++
                sec_title[secs] = t
                sec_start[secs] = is_pure(s[ns - 1]) ? ns - 1 : ns
                sec_end[secs - 1] = sec_start[secs] - 1
            }
        }
        sec_end[secs] = ns

        tail = nu
        for (sec = 0; sec <= secs; sec++) {
            missing = 0
            first_present = 0
            for (i = sec_start[sec]; i <= sec_end[sec]; i++) {
                k = keyof(s[i])
                if (k == "") continue
                if (k in ukey) { if (!first_present) first_present = ukey[k] }
                else missing++
            }
            t = sec_title[sec]
            has_title = (t != "" && (t in utitle))

            # A whole new section goes after the previous one the user has
            if (sec > 0 && !has_title && !first_present) {
                if (!missing) continue
                last = sec_end[sec]
                while (last > sec_start[sec] && s[last] ~ /^[ \t]*$/) last--
                add(tail, "")
                for (i = sec_start[sec]; i <= last; i++) {
                    add(tail, s[i])
                    k = keyof(s[i])
                    if (k != "") report(k)
                }
                continue
            }

            if (has_title) anchor = after_header(utitle[t])
            else if (sec > 0) anchor = first_present - 1
            else anchor = 0

            for (i = sec_start[sec]; i <= sec_end[sec]; i++) {
                k = keyof(s[i])
                if (k == "") continue
                if (k in ukey) { anchor = ukey[k]; continue }
                # Bring along the comments directly above the new line
                j = i - 1
                while (j >= sec_start[sec] && is_note(s[j])) j--
                if (j >= sec_start[sec] && s[j] ~ /^[ \t]*$/) add(anchor, "")
                for (j++; j <= i; j++) add(anchor, s[j])
                report(k)
            }

            if (has_title) {
                tail = section_end(utitle[t])
                if (anchor > tail) tail = anchor
            } else if (sec > 0) {
                tail = anchor
            } else {
                tail = nu
                for (i = 1; i <= nu; i++) {
                    if (titleof(u[i]) != "") { tail = section_end(i - 1); break }
                }
                if (anchor > tail) tail = anchor
            }
        }

        for (i = 0; i <= nu; i++) {
            if (i > 0) print uraw[i]
            if (!(i in ins)) continue
            block = ins[i]
            if ((i == 0 || u[i] ~ /^[ \t]*$/) && substr(block, 1, 1) == "\n") block = substr(block, 2)
            lines = split(block, out, "\n")
            for (j = 1; j < lines; j++) print out[j] eol
        }
    }
    '
}

awk_merge_compose() {
    awk -v BINMODE=3 -v user="$1" -v src="$2" -v added="$ADDED_FILE" '
    function clean(s) { sub(/\r$/, "", s); return s }
    function pathof(s) {
        if (s !~ /^[ \t]*(#[ \t]*)?-[ \t]+/) return ""
        sub(/^[ \t]*(#[ \t]*)?-[ \t]+/, "", s)
        sub(/^path:[ \t]*/, "", s)
        sub(/[ \t].*$/, "", s)
        gsub(/["\047]/, "", s)
        return s ~ /\.ya?ml$/ ? s : ""
    }
    function commented(s) {
        if (s ~ /^[ \t]*-/) sub(/-/, "# -", s)
        return s
    }
    function add(anchor, line) { ins[anchor] = ins[anchor] line eol "\n" }
    BEGIN {
        while ((getline raw < user) > 0) {
            if (nu == 0 && raw ~ /\r$/) eol = "\r"
            nu++
            uraw[nu] = raw
            u[nu] = clean(raw)
            if (!inc && u[nu] ~ /^include:/) inc = nu
            else if (inc && !done && u[nu] ~ /^[^ \t#]/) done = 1
            if (inc && !done && nu > inc) {
                p = pathof(u[nu])
                if (p != "") uent[p] = nu
            }
        }
        while ((getline raw < src) > 0) {
            line = clean(raw)
            if (!started) { if (line ~ /^include:/) started = 1; continue }
            if (line ~ /^[^ \t#]/) break
            nt++
            t[nt] = line
        }

        if (!inc) {
            add(nu, "")
            add(nu, "include:")
            for (i = 1; i <= nt; i++) {
                add(nu, commented(t[i]))
                p = pathof(t[i])
                if (p != "") print p > added
            }
        } else {
            # Keep new entries below any table heading
            anchor = inc
            while (anchor < nu && u[anchor + 1] ~ /^[ \t]*#/ && pathof(u[anchor + 1]) == "") anchor++
            # Entries before the first known one go directly above it
            for (i = 1; i <= nt; i++) {
                p = pathof(t[i])
                if (p != "" && (p in uent)) { anchor = uent[p] - 1; break }
            }
            for (i = 1; i <= nt; i++) {
                p = pathof(t[i])
                if (p == "") continue
                if (p in uent) { anchor = uent[p]; continue }
                add(anchor, commented(t[i]))
                print p > added
            }
        }

        for (i = 0; i <= nu; i++) {
            if (i > 0) print uraw[i]
            if (i in ins) printf "%s", ins[i]
        }
    }
    '
}

# Print the active entries in the top level include block
active_includes() {
    awk '
    { sub(/\r$/, "") }
    /^include:/ { inc = 1; next }
    /^[^ \t#]/ { inc = 0 }
    inc && /^[ \t]*-[ \t]+/ {
        sub(/^[ \t]*-[ \t]+/, "")
        sub(/^path:[ \t]*/, "")
        sub(/[ \t].*$/, "")
        gsub(/["\047]/, "")
        print
    }
    ' "$1"
}

awk_edit_include() {
    awk -v BINMODE=3 -v mode="$2" -v target="$3" '
    {
        line = $0
        sub(/\r$/, "", line)
    }
    /^include:/ { inc = 1; print; next }
    line ~ /^[^ \t#]/ { inc = 0 }
    inc && line ~ /^[ \t]*-[ \t]+/ {
        p = line
        sub(/^[ \t]*-[ \t]+/, "", p)
        sub(/^path:[ \t]*/, "", p)
        sub(/[ \t].*$/, "", p)
        gsub(/["\047]/, "", p)
        if (p == target) {
            if (mode == "remove") next
            sub(/-/, "# -")
        }
    }
    { print }
    ' "$1"
}

ask_removed_service() {
    local answer
    if [ "$AUTO_YES" -eq 1 ]; then
        echo comment
        return
    fi
    while true; do
        read -r -p "[C]omment out or [r]emove the line? " answer || answer="c"
        case "$answer" in
        c | C | "")
            echo comment
            return
            ;;
        r | R)
            echo remove
            return
            ;;
        esac
    done
}

# Includes of services that have gone from the repository would break compose
handle_removed_services() {
    local file=$1 entry action entries
    mapfile -t entries < <(active_includes "$file")
    for entry in "${entries[@]}"; do
        case "$entry" in
        *'$'* | *://*) continue ;;
        esac
        [ ! -e "$entry" ] || continue
        echo "$file includes \"$entry\", which no longer exists."
        action=$(ask_removed_service)
        rewrite "$file" awk_edit_include "$file" "$action" "$entry"
        echo "  $action: $entry"
    done
}

merge_file() {
    local file=$1 source=$2 merger=$3
    if [ ! -f "$file" ]; then
        echo "Skipping $file, it does not exist (see the README.md file)."
        return
    fi
    ADDED_FILE=$(mktemp) || die "Could not create a temporary file."
    "$merger" "$file" "$source" >/dev/null || die "Could not read $file."
    if [ -s "$ADDED_FILE" ]; then
        rewrite "$file" "$merger" "$file" "$source"
        echo "Added to $file:"
        sed 's/^/  + /' "$ADDED_FILE"
    fi
    rm -f "$ADDED_FILE"
    ADDED_FILE=""
}

check_compose() {
    if docker compose config --quiet >/dev/null 2>&1; then
        return 0
    fi
    warn "The docker compose configuration is broken:"
    docker compose config --quiet
    return 1
}

main() {
    local option
    while getopts "yfh" option; do
        case "$option" in
        y) AUTO_YES=1 ;;
        f) AUTO_UP=1 ;;
        h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 2
            ;;
        esac
    done

    cd "$(dirname "${BASH_SOURCE[0]}")" || die "Could not find the repository."
    trap on_exit EXIT

    check_git_state
    git pull --quiet --ff-only || die "Could not pull the latest version."

    # Before the checks below, so that they see what is really going to run
    unstash

    merge_file .env .env.example awk_merge_env
    merge_file .env.keep-alive .env.keep-alive.example awk_merge_env
    merge_file compose.override.yaml compose.override.yaml.template awk_merge_compose
    [ ! -f compose.override.yaml ] || handle_removed_services compose.override.yaml

    check_compose || exit 1
    [ "$STASH_FAILED" -eq 0 ] || exit 1

    if [ "$AUTO_UP" -eq 1 ]; then
        docker compose up -d || exit 1
    else
        echo "Run \"docker compose up -d\" to use the new settings."
    fi
}

main "$@"; exit $?
