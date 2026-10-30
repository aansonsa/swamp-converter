#!/bin/zsh
# Copies the project into a clean folder that is ready to become a Git repository: no ._* files (exFAT), no dist/, no AI-tool folders, no local databases.
# Then it proves the copy stands on its own: check-modules and typecheck run inside it with a cache of its own.
# Usage: scripts/export-for-git.sh [destination]     (default: ~/Library/Caches/SwampConverter/export/<timestamp>)
# Never touches the original, never runs git init, never pushes.

setopt err_return pipe_fail
SCRIPT=${0:A}
PROJECT=${SCRIPT:h:h}
STAMP=$(date +%Y%m%d-%H%M%S)
DEST=${1:-$HOME/Library/Caches/SwampConverter/export/$STAMP}
[[ -e $DEST ]] && { print -u2 "export-for-git: $DEST already exists"; exit 1 }
mkdir -p $DEST

# --exclude lines mirror .gitignore; the ._* AppleDouble files are the exFAT drive's own noise.
rsync -a \
  --exclude='._*' --exclude='.DS_Store' --exclude='dist/' --exclude='*.part' \
  --exclude='.claude/' --exclude='.claude-flow/' --exclude='.swarm/' \
  --exclude='agentdb.rvf' --exclude='agentdb.rvf.idmap.json' --exclude='ruvector.db' \
  --exclude='.git/' \
  $PROJECT/ $DEST/

# exFAT reports every file as executable (755); Git would record that for every PNG and source file. Only the shell scripts keep the bit.
find $DEST -type f -exec chmod 644 {} +
find $DEST -type f -name '*.sh' -exec chmod 755 {} +
find $DEST -type d -exec chmod 755 {} +

print -- "exported to $DEST ($(find $DEST -type f | wc -l | tr -d ' ') files, $(du -sh $DEST | cut -f1))"
leftovers=$(find $DEST \( -name '._*' -o -name '.DS_Store' -o -name dist -o -name .claude -o -name .swarm -o -name .claude-flow -o -name ruvector.db \) | head -5)
[[ -z $leftovers ]] || { print -u2 "export-for-git: leftovers in the copy:\n$leftovers"; exit 1 }

# The copy must build by itself: a cache of its own, no reuse of the original's build products. The cache lives outside the copy, so the copy stays clean
# and this script never deletes anything.
export SC_CACHE=$HOME/Library/Caches/SwampConverter/export-cache/$STAMP
cd $DEST
./build.sh check-modules
./build.sh typecheck all
print -- "ok: the exported copy passes check-modules and typecheck all. Next steps (yours): git init, review, commit, push."
