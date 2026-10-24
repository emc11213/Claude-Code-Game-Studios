#!/usr/bin/env bash
# ci-check.sh — the template's own CI: checks the framework, not a game built
# with it. Run by .github/workflows/ci.yml on Linux, macOS and Windows; runs the
# same way locally from Git Bash or any POSIX shell.
#
# The helpers in .claude/scripts/ print OBSERVATIONS, NEVER VERDICTS. This
# script is the one place that turns some of those observations into a verdict,
# and only for the facts that are never a judgement call: a script that does
# not parse, a skill with no frontmatter, a catalog entry with no skill behind
# it, a README count that is wrong. Anything a reader has to weigh (overlapping
# agent descriptions, how many phases a skill needs) stays with /skill-test.
#
# Usage: bash .github/scripts/ci-check.sh [check ...]
#   checks: syntax settings catalog counts skills agents hooks (default: all)
#
# Environment:
#   CCGS_BASH  the bash that runs every helper and hook; CI sets /bin/bash on
#              macOS so the bash 3.2 floor the helpers promise is what runs
#
# Exit codes: 0 every check passed; 1 at least one failed; 2 usage error.
#
# bash 3.2 and BWK awk safe, no Python (agent-check.sh itself needs Python 3).

set -u
LC_ALL=C; export LC_ALL

cd "$(dirname "$0")/../.." || { echo "ci-check: cannot reach the repo root" >&2; exit 1; }

BASH_BIN="${CCGS_BASH:-bash}"
FAILS=0
WARNS=0
TMP=$(mktemp -d 2>/dev/null) || { echo "ci-check: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

# In GitHub Actions a failure is also an annotation, so it shows on the PR.
fail() {
  FAILS=$((FAILS + 1))
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*"; else printf 'FAIL  %s\n' "$*"; fi
}
warn() {
  WARNS=$((WARNS + 1))
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::warning::%s\n' "$*"; else printf 'WARN  %s\n' "$*"; fi
}
ok()      { printf 'ok    %s\n' "$*"; }
section() { printf '\n== %s\n' "$1"; }

# jq prints CRLF on Windows; every read of its output goes through this.
jqr() { jq -r "$@" | tr -d '\r'; }

need_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  fail "$1: jq is not installed, so this check cannot run"
  return 1
}

# The skills and agents that exist on disk: the reference every other list is
# compared with.
ls .claude/skills/*/SKILL.md 2>/dev/null | sed 's|^\.claude/skills/||; s|/SKILL\.md$||' | sort > "$TMP/skills.fs"
ls .claude/agents/*.md 2>/dev/null | sed 's|^\.claude/agents/||; s|\.md$||' | sort > "$TMP/agents.fs"
N_SKILLS=$(wc -l < "$TMP/skills.fs" | tr -d ' ')
N_AGENTS=$(wc -l < "$TMP/agents.fs" | tr -d ' ')

# --- syntax: every tracked shell script parses --------------------------------
check_syntax() {
  section "syntax: bash -n on every tracked .sh ($BASH_BIN)"
  _n=0; _bad=0
  for f in $(git ls-files -- '*.sh'); do
    _n=$((_n + 1))
    if ! "$BASH_BIN" -n "$f" 2> "$TMP/err"; then
      _bad=$((_bad + 1))
      fail "$f does not parse: $(head -1 "$TMP/err")"
    fi
    # A CRLF script breaks Git Bash; .gitattributes should prevent it.
    if grep -q "$(printf '\r')" "$f"; then
      _bad=$((_bad + 1))
      fail "$f has CRLF line endings (.gitattributes asks for LF)"
    fi
  done
  [ "$_bad" -eq 0 ] && ok "$_n scripts parse, all LF"
}

# --- settings: valid JSON, and every hook it names exists ---------------------
check_settings() {
  section "settings: .claude/settings.json"
  need_jq settings || return
  if ! jq -e . .claude/settings.json > /dev/null 2> "$TMP/err"; then
    fail ".claude/settings.json is not valid JSON: $(head -1 "$TMP/err")"
    return
  fi
  ok "valid JSON"
  _missing=0
  for p in $(jqr '.. | objects | .command? // empty' .claude/settings.json \
             | grep -oE '\.claude/[A-Za-z0-9_./-]+\.sh' | sort -u); do
    [ -f "$p" ] || { _missing=$((_missing + 1)); fail "settings.json runs $p, which does not exist"; }
  done
  [ "$_missing" -eq 0 ] && ok "every script settings.json runs exists"
}

# --- catalog: studio-tests/catalog.yaml matches what is on disk ---------------
# The catalog is machine-written and two levels deep; awk reads the `- name:`
# and `spec:` of each entry under the top-level skills: and agents: blocks.
check_catalog() {
  section "catalog: studio-tests/catalog.yaml"
  _cat=studio-tests/catalog.yaml
  [ -f "$_cat" ] || { fail "$_cat is missing"; return; }
  tr -d '\r' < "$_cat" | awk '
    /^skills:/ { b = "skill"; next }
    /^agents:/ { b = "agent"; next }
    /^[^ #]/   { b = "" }
    b == ""    { next }
    /^  - name:/ { n = $0; sub(/^  - name:[ ]*/, "", n); gsub(/"/, "", n); print b "\tname\t" n }
    /^    spec:/ { s = $0; sub(/^    spec:[ ]*/, "", s); gsub(/"/, "", s); print b "\tspec\t" n "\t" s }
  ' > "$TMP/catalog.tsv"
  _before=$FAILS
  for kind in skill agent; do
    awk -F '\t' -v k="$kind" '$1 == k && $2 == "name" { print $3 }' "$TMP/catalog.tsv" | sort > "$TMP/$kind.cat"
    for d in $(uniq -d "$TMP/$kind.cat"); do fail "catalog lists $kind $d more than once"; done
    sort -u "$TMP/$kind.cat" > "$TMP/$kind.catu"
    for x in $(comm -23 "$TMP/${kind}s.fs" "$TMP/$kind.catu"); do fail "$kind $x exists but is not in $_cat"; done
    for x in $(comm -13 "$TMP/${kind}s.fs" "$TMP/$kind.catu"); do fail "$_cat lists $kind $x, which does not exist"; done
  done
  while IFS="$(printf '\t')" read -r kind _ name spec; do
    [ -z "$spec" ] && continue
    [ -f "$spec" ] || fail "catalog spec for $kind $name points at $spec, which does not exist"
  done <<EOF
$(awk -F '\t' '$2 == "spec"' "$TMP/catalog.tsv")
EOF
  [ "$FAILS" -eq "$_before" ] && ok "$N_SKILLS skills and $N_AGENTS agents, all catalogued, every spec path exists"
}

# --- counts: the numbers the docs state match the folders ---------------------
check_counts() {
  section "counts: README and CLAUDE.md state $N_SKILLS skills, $N_AGENTS agents"
  _before=$FAILS
  for f in README.md CLAUDE.md studio-tests/README.md studio-tests/CLAUDE.md; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" | grep -noE \
      '[0-9]+ (specialized |coordinated Claude Code )?(agents|subagents|agent definitions)|badge/agents-[0-9]+|\*\*Agents\*\* [|] [0-9]+' \
      | while IFS=: read -r line m; do
          n=$(printf '%s' "$m" | grep -oE '[0-9]+' | head -1)
          [ "$n" = "$N_AGENTS" ] || echo "$f:$line says \"$m\"; .claude/agents/ holds $N_AGENTS"
        done
    tr -d '\r' < "$f" | grep -noE \
      '[0-9]+ (skills|slash commands)|badge/skills-[0-9]+|\*\*Skills\*\* [|] [0-9]+' \
      | while IFS=: read -r line m; do
          n=$(printf '%s' "$m" | grep -oE '[0-9]+' | head -1)
          [ "$n" = "$N_SKILLS" ] || echo "$f:$line says \"$m\"; .claude/skills/ holds $N_SKILLS"
        done
  done > "$TMP/counts"
  while IFS= read -r msg; do [ -n "$msg" ] && fail "$msg"; done < "$TMP/counts"
  [ "$FAILS" -eq "$_before" ] && ok "every stated count matches"
}

# --- skills: skill-lint.sh checks 1-7, failing only on frontmatter ------------
check_skills() {
  section "skills: .claude/scripts/skill-lint.sh all"
  if ! "$BASH_BIN" .claude/scripts/skill-lint.sh all > "$TMP/lint.tsv" 2> "$TMP/err"; then
    fail "skill-lint.sh exited non-zero: $(head -1 "$TMP/err")"
    return
  fi
  _before=$FAILS
  tr -d '\r' < "$TMP/lint.tsv" | awk -F '\t' -v want="$N_SKILLS" '
    $1 == "NOT_READ" { print "skill " $2 " was not read: " $3 }
    $1 == "check1" && ($3 != "frontmatter=ok" || $4 != "missing=-" || $5 != "name=match") {
      print "skill " $2 " frontmatter: " $3 " " $4 " " $5
    }
    $1 == "checked" { seen = 1; split($2, c, " of "); if (c[1] != c[2] || c[2] != want) print "skill-lint read " $2 " skills; " want " exist" }
    END { if (!seen) print "skill-lint printed no checked row" }
  ' > "$TMP/lint.fail"
  while IFS= read -r msg; do [ -n "$msg" ] && fail "$msg"; done < "$TMP/lint.fail"
  [ "$FAILS" -eq "$_before" ] && ok "$N_SKILLS skills: frontmatter complete, name matches folder"
}

# --- agents: agent-check.sh, failing only on frontmatter ----------------------
check_agents() {
  section "agents: .claude/scripts/agent-check.sh"
  if ! "$BASH_BIN" .claude/scripts/agent-check.sh > "$TMP/agents.out" 2> "$TMP/err"; then
    fail "agent-check.sh exited non-zero: $(head -1 "$TMP/err")"
    return
  fi
  _before=$FAILS
  tr -d '\r' < "$TMP/agents.out" | awk -v want="$N_AGENTS" '
    /^AGENT: / { n++; cur = $2; if ($3 != "frontmatter=ok") print "agent " cur ": " $3; next }
    /^(OVERLAP|DELEGATION)/ { cur = "" }
    cur != "" && $1 == "NOTE:" && $2 == "frontmatter" { d = $0; sub(/^[ ]*NOTE: frontmatter /, "", d); print "agent " cur " frontmatter: " d }
    END { if (n != want) print "agent-check read " n + 0 " agents; " want " exist" }
  ' > "$TMP/agents.fail"
  while IFS= read -r msg; do [ -n "$msg" ] && fail "$msg"; done < "$TMP/agents.fail"
  [ "$FAILS" -eq "$_before" ] && ok "$N_AGENTS agents: frontmatter parses"
  # The other observations are for a reader; list them so a PR shows a change.
  tr -d '\r' < "$TMP/agents.out" | awk '$1 == "NOTE:" && $2 != "frontmatter" { print $2 }' \
    | sort | uniq -c | while read -r c k; do printf 'info  %s NOTE: %s (advisory)\n' "$c" "$k"; done
}

# --- hooks: every hook settings.json registers runs and exits as documented ---
# Each hook gets a payload shaped like the event it is registered for. Exit 0
# (allow, or advisory) and 2 (block) are the two documented outcomes; anything
# else is a crash. A fresh checkout is the hardest case for them: no
# production/ state, no session logs.
check_hooks() {
  section "hooks: smoke run of every hook in settings.json ($BASH_BIN)"
  need_jq hooks || return
  _root=$(pwd -W 2>/dev/null || pwd)
  # An empty matcher becomes `*`: a tab is IFS whitespace, so `read` would
  # merge the empty field into the next and shift every column after it.
  jqr '.hooks | to_entries[] | .key as $e | .value[]
       | (.matcher // "" | if . == "" then "*" else . end) as $m
       | .hooks[] | [$e, $m, .command, ((.timeout // 60) | tostring)] | @tsv' \
    .claude/settings.json > "$TMP/hooks.tsv"
  _before=$FAILS; _n=0
  git diff --quiet || warn "the tree already had changes before the hooks ran"
  while IFS="$(printf '\t')" read -r event matcher cmd limit; do
    script=$(printf '%s' "$cmd" | grep -oE '\.claude/[A-Za-z0-9_./-]+\.sh' | head -1)
    [ -n "$script" ] || { warn "$event hook runs no script this check can find: $cmd"; continue; }
    case "$matcher" in
      *Bash*)  payload='{"hook_event_name":"'"$event"'","tool_name":"Bash","tool_input":{"command":"ls"}}' ;;
      *Write*) payload='{"hook_event_name":"'"$event"'","tool_name":"Write","tool_input":{"file_path":"'"$_root"'/src/ci-smoke.txt","content":"ci"}}' ;;
      Read)    payload='{"hook_event_name":"'"$event"'","tool_name":"Read","tool_input":{"file_path":"'"$_root"'/README.md"}}' ;;
      *)       payload='{"hook_event_name":"'"$event"'","session_id":"ci-smoke","cwd":"'"$_root"'"}' ;;
    esac
    _n=$((_n + 1))
    _t0=$SECONDS
    printf '%s' "$payload" | CLAUDE_PROJECT_DIR="$_root" "$BASH_BIN" "$script" > /dev/null 2> "$TMP/err"
    rc=$?
    _dt=$((SECONDS - _t0))
    case "$rc" in
      0|2) ;;
      *) fail "$event/$matcher $script exited $rc: $(head -1 "$TMP/err")" ;;
    esac
    grep -q 'syntax error' "$TMP/err" && fail "$event/$matcher $script: $(grep -m1 'syntax error' "$TMP/err")"
    grep -q 'command not found' "$TMP/err" && warn "$event/$matcher $script: $(grep -m1 'command not found' "$TMP/err")"
    [ "$_dt" -gt "$limit" ] && warn "$event/$matcher $script took ${_dt}s; settings.json allows ${limit}s"
  done < "$TMP/hooks.tsv"
  [ "$FAILS" -eq "$_before" ] && ok "$_n hook runs, each exited 0 or 2"
  # Hooks write session state; that belongs in ignored files, never tracked ones.
  for f in $(git diff --name-only); do warn "running the hooks changed tracked file $f"; done
}

ALL="syntax settings catalog counts skills agents hooks"
[ "$#" -eq 0 ] && set -- $ALL
for c in "$@"; do
  case " $ALL " in *" $c "*) ;; *) echo "ci-check: unknown check '$c' (known: $ALL)" >&2; exit 2 ;; esac
done
for c in "$@"; do "check_$c"; done

printf '\n%s failed, %s warnings\n' "$FAILS" "$WARNS"
[ "$FAILS" -eq 0 ]
