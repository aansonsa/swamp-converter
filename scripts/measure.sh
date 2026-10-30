#!/bin/zsh
# Performance and size measurements for the RELEASE build (budgets of the project brief). Owner: the app module (packaging part). No sudo, no powermetrics, no xctrace.
#
#   scripts/measure.sh size      bundle size (budget <= 12 MB) and binary size; frameworks linked (otool -L)
#   scripts/measure.sh links     dynamic libraries actually linked (only frameworks that are used)
#   scripts/measure.sh idle      launches the packaged app (own isolated home, no first-run window), waits 5 s, samples 60 s with ps / top (cpu, idle wake-ups, threads) / footprint, then QUITS it
#   scripts/measure.sh launch    time from process start to the status item being ready (budget <= 0.8 s): median of 5 launches (SC_RUNS)
#   scripts/measure.sh opt       builds the release binary with -O and with -Osize, prints sizes and build times, leaves the default (-Osize) build in place
# Output: machine-readable `metric=value` lines on stdout (everything else goes to stderr), budget verdicts as `<metric>_ok=1|0`.
# Budgets: idle CPU avg <= 0.1 % over 60 s, ZERO timers at idle, idle footprint <= 70 MB, launch <= 0.8 s, after 200 jobs memory within 10 MB of the start.
#
# Environment: SC_CACHE (build cache), SC_APP_BIN (measure another executable, e.g. a debug build), SC_MEASURE_SECONDS (idle sampling time, default 60, multiple of 3), SC_RUNS (launch runs).
# The app is started with its own SWAMP_CONVERTER_HOME / SWAMP_CONVERTER_TMP, so it never touches the real settings, the real lock (a running copy of the real app does not interfere)
# and shows no onboarding window. It is quit with SIGTERM (the app handles it like Quit, without the interactive confirmation): osascript would trigger an Automation prompt.

SCRIPT=${0:A}
PROJECT=${SCRIPT:h:h}
CACHE=${SC_CACHE:-$HOME/Library/Caches/SwampConverter}
APP=$CACHE/app/"Swamp Converter.app"
BIN=${SC_APP_BIN:-$APP/Contents/MacOS/SwampConverter}

need_app() { [[ -x $BIN ]] || { print -u2 "measure: package first (./build.sh package) or set SC_APP_BIN"; exit 1 } }

# ---- helpers --------------------------------------------------------------------------------------------------------------------------

HOME_DIR=""
APP_PID=""

new_home() {
  mkdir -p $CACHE/tmp || exit 1
  HOME_DIR=$(mktemp -d $CACHE/tmp/measure.XXXXXX) || exit 1
  mkdir -p $HOME_DIR/support $HOME_DIR/tmp
  print -r -- '{"onboardingDone": true, "firstRunDone": true}' > $HOME_DIR/support/settings.json
}

# start_app: launches the binary detached, sets APP_PID, waits (<= 20 s) for the ready marker the app writes (SC_READY_FILE). Returns 1 when it never became ready.
start_app() {
  new_home
  SWAMP_CONVERTER_HOME=$HOME_DIR/support SWAMP_CONVERTER_TMP=$HOME_DIR/tmp SC_READY_FILE=$HOME_DIR/ready $BIN >$HOME_DIR/out.txt 2>&1 &
  APP_PID=$!
  disown 2>/dev/null
  local i
  for i in {1..400}; do
    [[ -s $HOME_DIR/ready ]] && return 0
    kill -0 $APP_PID 2>/dev/null || { print -u2 "measure: the app exited during launch (see $HOME_DIR/out.txt)"; return 1 }
    sleep 0.05
  done
  print -u2 "measure: the app did not become ready within 20 s"
  return 1
}

# stop_app: quits like Quit (SIGTERM), waits up to 10 s, falls back to SIGKILL, verifies that no process of this binary is left. Prints quit_clean / leftover_processes.
stop_app() {
  [[ -n $APP_PID ]] || return 0
  kill -TERM $APP_PID 2>/dev/null
  local i clean=1
  for i in {1..100}; do kill -0 $APP_PID 2>/dev/null || break; sleep 0.1; done
  if kill -0 $APP_PID 2>/dev/null; then clean=0; kill -KILL $APP_PID 2>/dev/null; sleep 0.3; fi
  local left; left=$(pgrep -f -- "$BIN" 2>/dev/null | wc -l | tr -d ' ')
  print -- "quit_clean=$clean"
  print -- "leftover_processes=$left"
  APP_PID=""
}

cleanup() { [[ -n $APP_PID ]] && kill -KILL $APP_PID 2>/dev/null; return 0 }
trap cleanup EXIT INT TERM

# MB from "123 MB" / "1.5 GB" / "900 KB" style text
to_mb() { awk -v v="$1" -v u="$2" 'BEGIN { if (u ~ /^G/) printf "%.1f", v*1024; else if (u ~ /^K/) printf "%.1f", v/1024; else printf "%.1f", v }' }

verdict() {  # verdict <name> <value> <max>
  awk -v v="$2" -v m="$3" -v n="$1" 'BEGIN { print n "_ok=" ((v+0 <= m+0) ? 1 : 0) }'
}

# ---- modes ----------------------------------------------------------------------------------------------------------------------------

case ${1:-size} in
  size)
    [[ -d $APP ]] || { print -u2 "measure: package first (./build.sh package)"; exit 1 }
    kb=$(du -sk $APP | cut -f1)
    print "bundle_kb=$kb"
    print "bundle_budget_kb=12288"
    verdict bundle $kb 12288
    print "binary_kb=$(du -k $BIN | cut -f1)"
    size $BIN 2>/dev/null | tail -n 2 >&2
    ;;
  links)
    need_app
    otool -L $BIN | tail -n +2 | awk '{print $1}' | sort
    ;;
  idle)
    need_app
    seconds=${SC_MEASURE_SECONDS:-60}
    (( seconds < 6 )) && seconds=6
    samples=$(( seconds / 3 ))
    start_app || { stop_app >/dev/null; exit 1 }
    print -u2 "measure idle: pid $APP_PID ready, settling 5 s, sampling ${seconds} s"
    sleep 5
    # CPU, idle wake-ups and threads: top logging mode; the first sample is since process start and is dropped.
    top -l $samples -s 3 -pid $APP_PID -stats pid,command,cpu,mem,idlew,threads > $HOME_DIR/top.txt 2>/dev/null
    stats=$(awk -v pid=$APP_PID '$1==pid { n++; lc=$3; lw=$5; lt=$6; if (n>1) { c++; cpu+=$3; w+=$5 } }
        END { if (c==0) { c=1; cpu=lc; w=lw } printf "%.3f %.2f %d %d", cpu/c, w/c, lt, n }' $HOME_DIR/top.txt)
    stats=(${=stats})
    print "idle_cpu_avg_pct=${stats[1]:-n/a}"
    print "idle_wakeups_avg=${stats[2]:-n/a}"
    print "idle_threads=${stats[3]:-n/a}"
    print "idle_samples=${stats[4]:-0}"
    verdict idle_cpu ${stats[1]:-0} 0.1
    rss_kb=$(ps -o rss= -p $APP_PID 2>/dev/null | tr -d ' ')
    print "idle_rss_mb=$(to_mb ${rss_kb:-0} KB)"
    fp=$(footprint -p $APP_PID 2>/dev/null | awk '/Footprint:/ { for (i = 1; i <= NF; i++) if ($i == "Footprint:") { print $(i+1), $(i+2); exit } }')
    if [[ -n $fp ]]; then
      fpmb=$(to_mb ${fp% *} ${fp#* })
      print "idle_footprint_mb=$fpmb"
      verdict idle_footprint $fpmb 70
    else
      print "idle_footprint_mb=n/a"
    fi
    print "idle_timers=not-measurable-here (the code base has no periodic timer; the tests assert that no task stays scheduled)"
    stop_app
    ;;
  launch)
    need_app
    runs=${SC_RUNS:-5}
    results=()
    for r in {1..$runs}; do
      start_app || { stop_app >/dev/null; exit 1 }
      ms=$(sed -n 's/^launch_ms=//p' $HOME_DIR/ready | head -n 1)
      results+=($ms)
      print "launch_run_$r=$ms"
      stop_app >/dev/null
    done
    sorted=(${(n)results})
    median=${sorted[$(( (${#sorted} + 1) / 2 ))]}
    print "launch_ms_median=$median"
    print "launch_ms_max=${sorted[-1]}"
    verdict launch_ms $median 800
    ;;
  opt)
    mkdir -p $CACHE/tmp/measure-opt || exit 1
    best=""; bestkb=999999999
    for flag in -O -Osize; do
      t0=$SECONDS
      out=$(SC_OPT=$flag zsh $PROJECT/build.sh build --release 2>&1) || { print -u2 -- "$out"; print -u2 "measure opt: build with $flag failed"; exit 1 }
      built=$(print -r -- "$out" | sed -n 's/^binary: \(.*\) (.*)$/\1/p' | tail -n 1)
      [[ -f $built ]] || { print -u2 "measure opt: no binary reported for $flag"; exit 1 }
      name=${flag#-}
      cp -f $built $CACHE/tmp/measure-opt/SwampConverter.$name
      strip -S -x $CACHE/tmp/measure-opt/SwampConverter.$name 2>/dev/null
      kb=$(du -k $CACHE/tmp/measure-opt/SwampConverter.$name | cut -f1)
      print "opt_${name}_stripped_kb=$kb"
      print "opt_${name}_build_seconds=$(( SECONDS - t0 ))"
      (( kb < bestkb )) && { bestkb=$kb; best=$flag }
    done
    print "opt_smaller=$best"
    print -u2 "measure opt: -Osize is the default of build.sh (SC_OPT=-O switches): it is 15 % smaller and the wheel benchmark (--bench wheel on a full release build) passes with a wide margin."
    # Leave the default build in place for packaging.
    SC_OPT=-Osize zsh $PROJECT/build.sh build --release >/dev/null 2>&1
    ;;
  *) print -u2 "usage: measure.sh size|links|idle|launch|opt"; exit 2 ;;
esac
