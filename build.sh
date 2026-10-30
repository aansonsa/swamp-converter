#!/bin/zsh
# Swamp Converter: build, type-check, test, snapshot and package.
# The Xcode licence is not accepted on this Mac, so xcrun / xcodebuild / "swift build" are NEVER used:
# everything goes through the Command Line Tools swiftc with an explicit SDK.
#
#   ./build.sh snapshot-skeleton            freeze Sources/ + modules.json as the contract snapshot
#   ./build.sh typecheck <module-id|all>    fast type-check (module: pristine skeleton + that module's live files)
#   ./build.sh build [--release]            full compile into the build cache
#   ./build.sh selftest [filter]            build, then run  --self-test [filter]
#   ./build.sh conformance [filter]         build, run the conformance tests (every operation on real files, judged by independent readers) and write docs/conversion-matrix.md
#   ./build.sh snapshot <dir> [filter]      build, then run  --snapshot <dir> [filter]  (offscreen PNGs; filter = text in the snapshot name)
#   ./build.sh package                      assemble + ad-hoc sign "Swamp Converter.app", copy to dist/
#   ./build.sh run                          assemble a debug app and launch it
#   ./build.sh measure <what>               size | links | idle | launch | opt  (scripts/measure.sh; release budgets of the brief)
#   ./build.sh check-modules                verify that modules.json covers every source file exactly once
#   ./build.sh modules                      list module ids and their globs
#   ./build.sh gc                           show how much space old build leftovers use (never deletes anything)
#
# Environment: SC_MODULE=<module-id> makes build / selftest / snapshot / run use the PRISTINE skeleton plus that module's live files (the same file set as
# "typecheck <module-id>"), so one engineer's tests and snapshots run while the other modules are mid-edit: SC_MODULE=core ./build.sh selftest core;
# several modules at once are comma-separated (SC_MODULE=core,image,audio,pdfocr ./build.sh selftest conformance runs the real engines without waiting for the UI);
# SC_VERBOSE=1 prints the whole compiler log; SC_WARNINGS=1 prints warnings of successful runs;
# SC_CACHE overrides the build cache folder (default ~/Library/Caches/SwampConverter); SC_OPT=-O switches the release optimisation level (default -Osize: 15 % smaller; the wheel benchmark passes with a wide margin);
# SC_VERSION / SC_BUILD set the version strings of "package".
#
# This script never deletes directory trees: replaced artefacts are moved into $CACHE/trash/<stamp>/ so a
# concurrent reader never sees a half-deleted folder and the owner decides when to empty the trash.

setopt extended_glob null_glob
unsetopt nomatch 2>/dev/null

SCRIPT=${0:A}
PROJECT=${SCRIPT:h}
CACHE=${SC_CACHE:-$HOME/Library/Caches/SwampConverter}
SWIFTC=/Library/Developer/CommandLineTools/usr/bin/swiftc
SDK_DIR=/Library/Developer/CommandLineTools/SDKs
MODULES_JSON=$PROJECT/modules.json
TMPBASE=$CACHE/tmp
BINARY_NAME=SwampConverter
STAMP=$(date +%Y%m%d-%H%M%S).$$

die() { print -u2 -- "build.sh: $*"; exit 1 }

# ----------------------------------------------------------------------------------------------------
# Toolchain

resolve_sdk() {
  [[ -x $SWIFTC ]] || die "swiftc not found at $SWIFTC (install the Command Line Tools)"
  local best s v
  # The newest MacOSX<version>.sdk whose major version is 26 or higher (the app needs macOS 26): MacOSX26.5.sdk wins over the MacOSX26.sdk symlink, and a
  # future MacOSX27.sdk wins over both. Folder names that are not a version (MacOSX.sdk) are ignored.
  # SC_SDK_MAX_MAJOR=26 caps the choice: the GitHub runners carry a MacOSX27 SDK next to 26.5, and in that SDK @State is a macro whose plugin ships only
  # with Xcode, not with the Command Line Tools this script compiles with.
  best=$(for s in $SDK_DIR/MacOSX*.sdk(N); do
           v=${${s:t}#MacOSX}; v=${v%.sdk}
           [[ ${v%%.*} == <-> ]] && (( ${v%%.*} >= 26 && ${v%%.*} <= ${SC_SDK_MAX_MAJOR:-999} )) && print -- "$v $s"
         done | /usr/bin/sort -V | tail -n 1 | cut -d' ' -f2-)
  [[ -n $best && -d $best ]] || die "no MacOSX26 or newer SDK in $SDK_DIR${SC_SDK_MAX_MAJOR:+ (SC_SDK_MAX_MAJOR=$SC_SDK_MAX_MAJOR)}"
  SDK=$best
  COMMON=(-sdk $SDK -swift-version 5 -target arm64-apple-macos26.0 -module-cache-path $CACHE/ModuleCache
          -module-name SwampConverter -diagnostic-style llvm)
}

ensure_dirs() { mkdir -p $CACHE/ModuleCache $TMPBASE $CACHE/build $CACHE/app $CACHE/trash || die "cannot create cache folders in $CACHE" }

# Moves a path into the trash folder (inside the cache). Used instead of deleting.
trash_path() {
  local p=$1
  [[ -e $p || -L $p ]] || return 0
  mkdir -p $CACHE/trash/$STAMP
  mv -- "$p" "$CACHE/trash/$STAMP/${p:t}.$RANDOM"
}

# ----------------------------------------------------------------------------------------------------
# modules.json helpers (plutil only, no python)

module_ids() { /usr/bin/plutil -p $MODULES_JSON | sed -n 's/^  "\([^"]*\)" => \[.*$/\1/p' }

module_globs() {  # prints one glob per line; exit 1 when the module does not exist
  local id=$1 i=0 g
  /usr/bin/plutil -extract "$id" json -o /dev/null $MODULES_JSON 2>/dev/null || return 1
  while g=$(/usr/bin/plutil -extract "$id.$i" raw -o - $MODULES_JSON 2>/dev/null); do
    print -r -- $g
    (( i++ ))
  done
  return 0
}

# Does relative path $1 match one of the globs in the array named $2? ('*' matches across directories.)
matches_globs() {
  local rel=$1 pat
  for pat in "${(@P)2}"; do
    [[ $rel == ${~pat} ]] && return 0
  done
  return 1
}

live_sources() { (cd $PROJECT && find Sources -name '*.swift' -not -name '._*' | LC_ALL=C sort) }

# SHIPPING BUILD: the app people run does not carry the self-tests, the conformance oracles, the snapshot renderers or their fixtures (a third of the code, and the biggest part of
# the bundle). A release build leaves out the files that match SHIPPING_EXCLUDE (minus SHIPPING_KEEP, files that look like tests but are production code) and defines
# SC_SHIPPING, which the few call sites of the test registries check. `SC_FULL_RELEASE=1 ./build.sh build --release` keeps everything (the self-tests run against that binary).
SHIPPING_EXCLUDE='(/Tests/)|(Tests?[A-Z0-9]?[A-Za-z0-9]*\.swift$)|TestKit|TestSupport|TestOracles|TestMetrics|TestMeasure|Fixture|Snapshot|Conformance|Golden|Contract|SelfTest|Harness\.swift|Oracles?[A-Za-z]*\.swift$'
SHIPPING_KEEP='/(ByteReader|FormatSniffer|FormatSniffer\+Media|ZipProbe|ExternalProbe|TableFidelity)\.swift$'
shipping_sources() { live_sources | grep -Ev "$SHIPPING_EXCLUDE" ; live_sources | grep -E "$SHIPPING_EXCLUDE" | grep -E "$SHIPPING_KEEP" | LC_ALL=C sort }

# ----------------------------------------------------------------------------------------------------
# Compiler wrapper: compact diagnostics with file:line

# run_swiftc <label> <swiftc args...>
run_swiftc() {
  local label=$1; shift
  local logdir; logdir=$(mktemp -d $TMPBASE/log.XXXXXX) || die "cannot create temp dir"
  local log=$logdir/compiler.log
  local t0=$SECONDS
  "$SWIFTC" "$@" >$log 2>&1
  local rc=$?
  local nerr nwarn
  nerr=$(grep -c ': error: ' $log)
  nwarn=$(grep -c ': warning: ' $log)
  if (( rc != 0 )); then
    print -u2 -- "== $label FAILED ($nerr error(s), $nwarn warning(s), $((SECONDS - t0)) s)"
    if [[ -n $SC_VERBOSE ]]; then
      cat $log >&2
    elif (( nerr > 0 )); then
      # Every error with its source line and caret (llvm diagnostic style puts them on the next two lines).
      grep -A2 ': error: ' $log | grep -v '^--$' >&2
    else
      tail -n 40 $log >&2
    fi
    rm -f $log; rmdir $logdir 2>/dev/null
    return 1
  fi
  if [[ -n $SC_WARNINGS || -n $SC_VERBOSE ]]; then grep -A2 ': warning: ' $log | grep -v '^--$' >&2; fi
  print -- "== $label ok ($nwarn warning(s), $((SECONDS - t0)) s)"
  rm -f $log; rmdir $logdir 2>/dev/null
  return 0
}

# ----------------------------------------------------------------------------------------------------
# typecheck

typecheck_shipping() {
  local files=("${(@f)$(shipping_sources)}")
  (( ${#files} > 0 )) || die "no Swift sources found"
  (cd $PROJECT && run_swiftc "typecheck shipping (${#files} files)" $COMMON -D SC_SHIPPING -Onone -typecheck -enable-batch-mode -j 8 $files)
}

typecheck_live() {
  local files=("${(@f)$(live_sources)}")
  (( ${#files} > 0 )) || die "no Swift sources found"
  (cd $PROJECT && run_swiftc "typecheck all (${#files} files)" $COMMON -Onone -typecheck -enable-batch-mode -j 8 $files)
}

# A module is checked against the PRISTINE skeleton: every skeleton file the module does not own is read from the
# frozen snapshot, every file it owns (including new ones) is read live from the project. Nothing is copied or written.
# module_file_list <id> fills MODULE_FILES (absolute paths) and the counters MODULE_LIVE / MODULE_REPLACED.
module_file_list() {
  # <id> or <id>,<id>,...: several modules can be swapped from the pristine skeleton to their live files at once (SC_MODULE=core,image,audio ...).
  local ids=${1//,/ } id
  local -a globs
  globs=()
  for id in ${=ids}; do
    local -a one
    one=("${(@f)$(module_globs $id)}")
    (( ${#one} > 0 )) || die "unknown module '$id' (see ./build.sh modules)"
    globs+=("${one[@]}")
  done
  local skel=$CACHE/skeleton
  [[ -d $skel/Sources ]] || die "no skeleton snapshot yet; run ./build.sh snapshot-skeleton first"
  local rel
  MODULE_FILES=(); MODULE_LIVE=0; MODULE_REPLACED=0
  for rel in "${(@f)$(cd $skel && find Sources -name '*.swift' -not -name '._*' | LC_ALL=C sort)}"; do
    if matches_globs $rel globs; then (( MODULE_REPLACED++ )); else MODULE_FILES+=("$skel/$rel"); fi
  done
  for rel in "${(@f)$(live_sources)}"; do
    if matches_globs $rel globs; then MODULE_FILES+=("$PROJECT/$rel"); (( MODULE_LIVE++ )); fi
  done
}

typecheck_module() {
  module_file_list $1
  run_swiftc "typecheck $1 (skeleton + $MODULE_LIVE live file(s); $MODULE_REPLACED skeleton file(s) replaced)" $COMMON -Onone -typecheck -enable-batch-mode -j 8 $MODULE_FILES
}

cmd_typecheck() {
  local what=${1:-}
  [[ -n $what ]] || die "usage: ./build.sh typecheck <module-id|all>"
  if [[ $what == all ]]; then typecheck_live; elif [[ $what == shipping ]]; then typecheck_shipping; else typecheck_module $what; fi
}

# ----------------------------------------------------------------------------------------------------
# snapshot-skeleton: versioned folders + a symlink, so readers never see a half-written snapshot

cmd_snapshot_skeleton() {
  local force=0; [[ ${1:-} == --force ]] && force=1
  if (( ! force )); then typecheck_live || die "the live tree does not type-check; refusing to freeze a broken skeleton (use --force to override)"; fi
  check_modules_quiet || die "modules.json does not cover the sources exactly once (run ./build.sh check-modules)"
  local new=$CACHE/skeleton.$STAMP
  mkdir -p $new/Sources || die "cannot create $new"
  rsync -a --exclude '._*' $PROJECT/Sources/ $new/Sources/ || die "copy failed"
  cp $MODULES_JSON $new/modules.json
  print -- "frozen $(date '+%Y-%m-%d %H:%M:%S') from $PROJECT" >$new/STAMP
  local count; count=$(find $new/Sources -name '*.swift' | wc -l | tr -d ' ')
  # Replace the symlink (or move a plain folder from an older script version out of the way).
  if [[ -d $CACHE/skeleton && ! -L $CACHE/skeleton ]]; then trash_path $CACHE/skeleton; fi
  ln -sfn $new $CACHE/skeleton || die "cannot publish the snapshot"
  print -- "skeleton snapshot: $count Swift files -> $CACHE/skeleton (-> ${new:t})"
}

# ----------------------------------------------------------------------------------------------------
# build

cmd_build() {
  local release=0 a
  for a in "$@"; do [[ $a == --release ]] && release=1; done
  local cfg=debug; (( release )) && cfg=release
  local shipping=0
  if (( release )) && [[ -z ${SC_MODULE:-} && -z ${SC_FULL_RELEASE:-} ]]; then shipping=1; fi
  if (( release )) && [[ -n ${SC_FULL_RELEASE:-} ]]; then cfg=release-full; fi
  local files label_extra=""
  if [[ -n ${SC_MODULE:-} ]]; then
    module_file_list $SC_MODULE
    files=("${MODULE_FILES[@]}")
    cfg=$cfg-${SC_MODULE//,/+}
    label_extra=" [skeleton + live $SC_MODULE]"
  elif (( shipping )); then
    files=("${(@f)$(shipping_sources)}")
    label_extra=" [shipping: without self-tests, oracles and snapshots]"
  else
    files=("${(@f)$(live_sources)}")
  fi
  (( ${#files} > 0 )) || die "no Swift sources found"
  # Other engineers edit the live tree while we compile ("input file was modified during the build"): SC_SNAPSHOT=1 (the default when several modules are
  # swapped live) compiles a private copy of the exact file set instead. Diagnostics then name files inside $TMPBASE/snap.*; the copy is moved to the trash afterwards.
  local snap=""
  if [[ -n ${SC_SNAPSHOT:-} || ${SC_MODULE:-} == *,* ]]; then
    snap=$TMPBASE/snap.$STAMP
    local f rel; local -a copied; copied=()
    for f in $files; do
      if [[ $f == $PROJECT/* ]]; then rel=${f#$PROJECT/}; else rel=${f#$CACHE/skeleton/}; fi
      mkdir -p $snap/${rel:h}
      cp -p $f $snap/$rel || die "cannot snapshot $f"
      copied+=($snap/$rel)
    done
    files=("${copied[@]}")
  fi
  local tmp; tmp=$(mktemp -d $TMPBASE/bd.XXXXXX) || die "cannot create temp dir"
  local opt=(-Onone -wmo -num-threads 8)
  # Release: whole-module optimisation, dead stripping (package.sh also strips symbols). -Osize is the default (measured: 9.97 MB against 11.77 MB for -O, wheel open 25 ms of 80, frame 2.9 ms of 8); measure.sh opt compares them again.
  (( release )) && opt=(${=SC_OPT:--Osize} -wmo -num-threads 8 -Xlinker -dead_strip)
  (( shipping )) && opt+=(-D SC_SHIPPING)
  (cd $PROJECT && run_swiftc "build $cfg (${#files} files)$label_extra" $COMMON $opt $files -o $tmp/$BINARY_NAME)
  local rc=$?
  [[ -n $snap ]] && (( rc == 0 )) && trash_path $snap
  if (( rc != 0 )); then rmdir $tmp 2>/dev/null; return 1; fi
  mkdir -p $CACHE/build/$cfg
  mv -f $tmp/$BINARY_NAME $CACHE/build/$cfg/$BINARY_NAME
  rmdir $tmp 2>/dev/null
  BUILT_BINARY=$CACHE/build/$cfg/$BINARY_NAME
  print -- "binary: $BUILT_BINARY ($(du -h $BUILT_BINARY | cut -f1 | tr -d ' '))"
  return 0
}

with_watchdog() {  # with_watchdog <seconds> <command...>
  local secs=$1; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec failed: $!"' $secs "$@"
}

cmd_selftest() {
  cmd_build || return 1
  local filter=${1:-}
  print -- "== self-test ${filter:+(filter: $filter)}"
  # The conformance suite runs every operation on real media and takes minutes: SC_TIMEOUT (seconds, default 1800) bounds the whole run; every test also has its own watchdog.
  local limit=${SC_TIMEOUT:-1800}
  if [[ -n $filter ]]; then with_watchdog $limit $BUILT_BINARY --self-test $filter; else with_watchdog $limit $BUILT_BINARY --self-test; fi
  local rc=$?
  (( rc == 142 )) && print -u2 -- "self-test timed out after $limit s"
  return $rc
}

cmd_conformance() {
  # The matrix is rewritten only by a full run: a filtered run would leave a document that lists most operations as "not run".
  local filter=${1:-conformance}
  if [[ $filter == conformance ]]; then
    SC_CONFORMANCE_MATRIX=$PROJECT/docs/conversion-matrix.md cmd_selftest conformance
  else
    cmd_selftest $filter
  fi
}

cmd_snapshot() {
  local dir=${1:-} filter=${2:-}
  [[ -n $dir ]] || die "usage: ./build.sh snapshot <dir> [filter]"
  dir=${dir:A}
  case $dir in
    $PROJECT/*|$CACHE/*|/private/tmp/*|/tmp/*) ;;
    *) die "snapshot folder must be inside the project, the build cache or the scratch folder" ;;
  esac
  mkdir -p $dir || die "cannot create $dir"
  cmd_build || return 1
  print -- "== snapshots -> $dir"
  if [[ -n $filter ]]; then with_watchdog 300 $BUILT_BINARY --snapshot $dir $filter; else with_watchdog 300 $BUILT_BINARY --snapshot $dir; fi
  local rc=$?
  (( rc == 142 )) && print -u2 -- "snapshot run timed out after 300 s"
  return $rc
}

# ----------------------------------------------------------------------------------------------------
# package / run (the real work lives in scripts/package.sh so the packaging owner never touches this file)

cmd_package() {
  cmd_build --release || return 1
  source $PROJECT/scripts/package.sh
  package_app "$BUILT_BINARY" release dist
}

cmd_measure() {
  [[ -f $PROJECT/scripts/measure.sh ]] || die "scripts/measure.sh is missing"
  zsh $PROJECT/scripts/measure.sh "$@"
}

cmd_run() {
  cmd_build || return 1
  source $PROJECT/scripts/package.sh
  package_app "$BUILT_BINARY" debug nodist || return 1
  print -- "launching $PACKAGED_APP"
  open -n "$PACKAGED_APP"
}

# ----------------------------------------------------------------------------------------------------
# module bookkeeping

cmd_modules() {
  local id g
  for id in $(module_ids); do
    print -- "$id"
    for g in "${(@f)$(module_globs $id)}"; do print -- "    $g"; done
  done
}

# Prints problems (one per line) and returns non-zero when there are any.
check_modules_core() {
  local bad=0 rel id n
  local -a ids files owned cur
  local -A globmap
  ids=($(module_ids))
  files=("${(@f)$(live_sources)}")
  for id in $ids; do globmap[$id]="$(module_globs $id | tr '\n' '\t')"; done
  for rel in $files; do
    n=0; owned=()
    for id in $ids; do
      cur=("${(@ps:\t:)globmap[$id]}")
      if matches_globs $rel cur; then (( n++ )); owned+=($id); fi
    done
    if (( n == 0 )); then print -- "UNOWNED   $rel"; bad=1; fi
    if (( n > 1 )); then print -- "MULTIPLE  $rel -> ${owned[*]}"; bad=1; fi
  done
  return $bad
}

check_modules_quiet() { check_modules_core >/dev/null }

cmd_check_modules() {
  local out; out=$(check_modules_core); local rc=$?
  if (( rc != 0 )); then print -- "$out"; print -u2 -- "modules.json is inconsistent"; return 1; fi
  print -- "modules.json ok: $(live_sources | wc -l | tr -d ' ') Swift files, each owned by exactly one module"
}

cmd_gc() {
  print -- "build cache: $CACHE"
  du -sh $CACHE/* 2>/dev/null | sed 's/^/  /'
  print -- "Old artefacts live in $CACHE/trash. Nothing is ever deleted by this script; empty the folder yourself when you want the space back."
}

cmd_help() { sed -n '2,/^$/p' $SCRIPT | sed 's/^# \{0,1\}//' }

# ----------------------------------------------------------------------------------------------------

main() {
  local sub=${1:-help}; (( $# > 0 )) && shift
  case $sub in
    help|-h|--help) cmd_help; return 0 ;;
  esac
  resolve_sdk
  ensure_dirs
  export SC_PROJECT=$PROJECT   # the self-tests that audit the source tree (core.idle) find it through this
  case $sub in
    snapshot-skeleton) cmd_snapshot_skeleton "$@" ;;
    typecheck)         cmd_typecheck "$@" ;;
    build)             cmd_build "$@" ;;
    selftest)          cmd_selftest "$@" ;;
    conformance)       cmd_conformance "$@" ;;
    snapshot)          cmd_snapshot "$@" ;;
    package)           cmd_package "$@" ;;
    run)               cmd_run "$@" ;;
    measure)           cmd_measure "$@" ;;
    check-modules)     cmd_check_modules "$@" ;;
    modules)           cmd_modules "$@" ;;
    gc)                cmd_gc "$@" ;;
    *) print -u2 -- "unknown command '$sub'"; cmd_help >&2; return 2 ;;
  esac
}

main "$@"
exit $?
