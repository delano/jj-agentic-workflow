#!/usr/bin/env bash
# Re-checks facts in HAZARDS.md against the installed jj, in throwaway repos with an
# isolated jj config (~/.config/jj is not read).
#   bash tests/hazards.sh            JJ_LAB_DIR=<dir> puts the lab somewhere specific
# FACT:  the behaviour in HAZARDS.md is unchanged on this jj.
# DRIFT: jj behaves differently now; update HAZARDS.md.
# Section numbers match HAZARDS.md. Derived from tests/multi-writer-hazards.sh in
# CodeAlive-AI/jj-agentic-workflow (MIT), with the checks of upstream's own guards removed.
set -uo pipefail
command -v jj >/dev/null || { echo "jj not found on PATH" >&2; exit 2; }
LAB="${JJ_LAB_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/jj-hazards.XXXXXX")}"
mkdir -p "$LAB"
export JJ_CONFIG="$LAB/config.toml"
printf '[user]\nname = "Hazard Lab"\nemail = "lab@example.invalid"\n' > "$JJ_CONFIG"

N_FACT=0; N_DRIFT=0
fact()  { printf '  \033[32mFACT\033[0m   %s\n' "$*"; N_FACT=$((N_FACT+1)); }
drift() { printf '  \033[33mDRIFT\033[0m  %s\n' "$*"; N_DRIFT=$((N_DRIFT+1)); }
say()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
q()     { jj -R "$1" --ignore-working-copy "${@:2}" 2>/dev/null; }  # read without snapshotting
files() { q "$1" log -r "$2" --no-graph -T 'diff.files().map(|f| f.path()).join(",")'; }
cid()   { q "$1" log -r "$2" --no-graph -T 'commit_id'; }
desc()  { q "$1" log -r "$2" --no-graph -T 'description.first_line()'; }
mk() { # $1 name -> repo path: commit "base" under bookmark main, @ is an empty child "next"
  local d="$LAB/r-$1"; rm -rf "$d" "$d-w"; mkdir -p "$d"
  ( cd "$d"; jj git init --colocate; echo base > base.txt
    jj describe -m base; jj new -m next; jj bookmark create main -r @- ) >/dev/null 2>&1
  echo "$d"
}

echo "$(jj --version); lab: $LAB"

say "§1 reads write"
R=$(mk reads)
( cd "$R"; jj describe -m task; echo stray > stray.txt ) >/dev/null 2>&1
case "$(files "$R" @)" in
  *stray*) drift "--ignore-working-copy snapshotted stray.txt" ;;
  *) fact "--ignore-working-copy left stray.txt out of the change" ;;
esac
( cd "$R"; jj status ) >/dev/null 2>&1
case "$(files "$R" @)" in
  *stray*) fact "bare jj status pulled stray.txt into the change" ;;
  *) drift "jj status did not snapshot stray.txt" ;;
esac

say "§2 no untracked state, and captured secrets persist"
R=$(mk secret)
( cd "$R"; jj describe -m task; echo "TOKEN=one" > .env; jj status ) >/dev/null 2>&1
case "$(files "$R" @)" in
  *.env*) fact "a new .env joined the change on the next jj command" ;;
  *) drift ".env was not tracked" ;;
esac
( cd "$R"; echo .env > .gitignore; echo "TOKEN=two" > .env; jj status ) >/dev/null 2>&1
case "$(files "$R" @)" in
  *.env*) fact "adding .env to .gitignore did not untrack it" ;;
  *) drift ".gitignore alone untracked .env" ;;
esac
( cd "$R"; jj file untrack .env ) >/dev/null 2>&1
case "$(files "$R" @)" in
  *.env*) drift "jj file untrack did not remove .env from the change" ;;
  *) fact "jj file untrack removed .env from the change" ;;
esac
[ -f "$R/.env" ] && fact "untrack left .env on disk" || drift "untrack deleted .env from disk"
LEAK=no
for c in $(q "$R" evolog -r @ --no-graph -T 'commit.commit_id().short() ++ "\n"'); do
  q "$R" file show -r "commit_id(\"$c\")" 'root:.env' >/dev/null && LEAK=yes
done
[ "$LEAK" = yes ] && fact "the old .env content is still readable through jj evolog" \
                  || drift "jj evolog no longer exposes the old .env"

say "§3 undo and op restore"
recov() { # $1 label, $2 command run in workspace a -> description of workspace b's change
  local d="$LAB/r3-$1"; rm -rf "$d" "$d-b"; mkdir -p "$d"
  ( cd "$d"; jj git init --colocate; echo base > base.txt; jj describe -m base
    jj new -m next; jj bookmark create main -r @- ) >/dev/null 2>&1
  jj -R "$d" workspace add --name b -r main -m "b: task" "$d-b" >/dev/null 2>&1
  ( cd "$d"; echo junk > a.txt; jj describe -m "a: oops" ) >/dev/null 2>&1
  local op; op=$(q "$d" op log --no-graph -T 'id ++ "\n"' | sed -n 2p)
  ( cd "$d-b"; echo w > b.txt; jj describe -m "b: real work" ) >/dev/null 2>&1
  ( cd "$d"; eval "${2//@OP@/$op}" ) >/dev/null 2>&1
  desc "$d-b" @
}
case "$(recov undo "jj undo")" in
  *"real work"*) fact "jj undo refused to revert the other workspace's operation (0.46+)" ;;
  *) drift "jj undo reverted the other workspace's work (expected before 0.46)" ;;
esac
case "$(recov op-restore "jj op restore @OP@")" in
  *"real work"*) drift "jj op restore left the other workspace's work intact" ;;
  *) fact "jj op restore rewound the other workspace's work" ;;
esac
for m in "abandon:jj abandon @ --retain-bookmarks" "describe:jj describe -m 'a: corrected'"; do
  case "$(recov "${m%%:*}" "${m#*:}")" in
    *"real work"*) fact "forward ${m%%:*} left the other workspace intact" ;;
    *) drift "forward ${m%%:*} damaged the other workspace" ;;
  esac
done

say "§4 a deleted Git ref can delete file content"
gitref() { # $1 name, $2 value for git.abandon-unreachable-commits ("" = jj default) -> tip files
  local R tip; R=$(mk "$1")
  [ -n "$2" ] && ( cd "$R"; jj config set --repo git.abandon-unreachable-commits "$2" ) >/dev/null 2>&1
  ( cd "$R"; jj new main -m feature; echo work > work.txt; jj bookmark create feature -r @
    jj new -m follow-up; echo more > more.txt; jj status; jj git export ) >/dev/null 2>&1
  ( cd "$R"; git update-ref -d refs/heads/feature; jj status ) >/dev/null 2>&1
  tip=$(q "$R" log -r 'heads(all() & ~empty())' --no-graph -T 'commit_id ++ "\n"' | head -1)
  q "$R" file list -r "commit_id(\"$tip\")" | tr '\n' ' '
}
case "$(gitref ref-default "")" in
  *work.txt*) drift "with the default config, work.txt survived the Git ref deletion" ;;
  *) fact "with the default config, deleting the Git ref dropped work.txt from the descendant" ;;
esac
case "$(gitref ref-false false)" in
  *work.txt*) fact "with abandon-unreachable-commits = false, work.txt survived" ;;
  *) drift "work.txt was lost even with abandon-unreachable-commits = false" ;;
esac

say "§7 jj abandon moves bookmarks without warning"
merged() { # $1 name -> repo where main points at "merged work" and @ is its empty child
  local R; R=$(mk "$1")
  ( cd "$R"; jj new main -m "merged work"; echo w > w.txt; jj bookmark set main -r @
    jj new -m next ) >/dev/null 2>&1
  echo "$R"
}
R=$(merged abandon); MAIN=$(cid "$R" main)
( cd "$R"; jj abandon "commit_id(\"$MAIN\")" ) >/dev/null 2>&1
[ -z "$(cid "$R" 'bookmarks(exact:"main")')" ] && fact "abandoning main's commit deleted the main bookmark" \
                                               || drift "main survived jj abandon"
R=$(merged retain); MAIN=$(cid "$R" main); PARENT=$(cid "$R" "commit_id(\"$MAIN\")-")
( cd "$R"; jj abandon "commit_id(\"$MAIN\")" --retain-bookmarks ) >/dev/null 2>&1
[ "$(cid "$R" 'bookmarks(exact:"main")')" = "$PARENT" ] && fact "--retain-bookmarks moved main back to the parent" \
                                                       || drift "unexpected --retain-bookmarks result"
OUT=$( cd "$R"; jj config set --repo aliases.abandon '["status"]' 2>&1; jj abandon --help 2>&1 | head -2 )
case "$OUT" in
  *"Cannot define an alias that overrides"*) fact "jj refuses an alias that shadows abandon" ;;
  *) drift "an alias can now shadow abandon: $OUT" ;;
esac

say "§9 absence is not an error"
R=$(mk revset)
( cd "$R"; jj describe -m "fix: typo" ) >/dev/null 2>&1
OUT=$(jj -R "$R" --ignore-working-copy log -r 'description("fix")' --no-graph -T 'commit_id ++ "\n"' 2>&1); RC=$?
N=$(printf '%s' "$OUT" | grep -c .)
[ "$RC" = 0 ] && [ "$N" = 0 ] && fact 'description("fix") matched nothing and exited 0' \
                              || drift "description(\"fix\") exited $RC with $N lines of output"
N=$(q "$R" log -r 'description(substring:"fix")' --no-graph -T 'commit_id ++ "\n"' | grep -c .)
[ "$N" = 1 ] && fact 'description(substring:"fix") matched the commit' \
             || drift "description(substring:\"fix\") matched $N commits"

say "§10 workspace add without -r starts from the parent of @"
R=$(mk wsbase); MAIN=$(cid "$R" main)
( cd "$R"; jj describe -m "my task"; echo t > t.txt; jj status
  jj workspace add --name w "$R-w" ) >/dev/null 2>&1
if [ -d "$R-w/.jj" ]; then
  [ "$(cid "$R-w" '@-')" = "$MAIN" ] && fact "the new workspace is based on main, not on the creator's task change" \
                                     || drift "the new workspace is based on something other than the parent of @"
else
  drift "jj workspace add failed here, so the base could not be checked"
fi

printf '\n\033[1m%d fact, %d drift\033[0m (lab: %s)\n' "$N_FACT" "$N_DRIFT" "$LAB"
[ "$N_DRIFT" -eq 0 ]
