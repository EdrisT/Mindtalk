#!/bin/zsh
# Quit Mindtalk, wait for it to be gone, launch a bundle, and only then believe a pid.
#
#   scripts/relaunch.sh quit   <name>
#   scripts/relaunch.sh launch <name> <bundle>
#
# Two commands rather than one, because `make install` has to replace the bundle between
# them: it cannot delete the app of a process that is still alive. `quit` guarantees there
# is no instance left, so a pid found after `launch` is the one just started — no need to
# compare pids, and no chance of mistaking an old build for a new one.
#
# `open` answers before the app is up, and refuses a second instance of an app that is
# still quitting. Hence the waits, and the check after: without them `make run` says OK and
# shows you the build from before.
#
# Failure lines are shaped `word: error: …` so the build-log filter — the one that reads
# `^[^ ].*(error|warning):` — keeps them.

name=$2
case $1 in
  quit)
    name=$2
    pgrep -x $name > /dev/null || exit 0            # nothing to quit: that is the easy case
    pkill -x $name 2> /dev/null
    for _ (1 2 3 4 5 6 7 8 9 10 11 12 13 14 15) do  # up to three seconds, then give up
      pgrep -x $name > /dev/null || exit 0
      sleep 0.2
    done
    echo "relaunch.sh: error: $name pid $(pgrep -x $name | tr '\n' ' ') would not quit — kill it before building again"
    exit 1
    ;;
  launch)
    name=$2
    bundle=$3
    if [[ -z $bundle ]]; then
      echo "relaunch.sh: error: launch needs a bundle to open"
      exit 2
    fi
    open $bundle
    sleep 1.2
    pid=$(pgrep -x $name)
    if [[ -z $pid ]]; then
      echo "relaunch.sh: error: $name is not running after opening $bundle"
      exit 1
    fi
    echo "$name running, pid $(echo $pid | tr '\n' ' ')"    ;;
  *)
    echo "relaunch.sh: error: says quit or launch, not $1"
    exit 2
    ;;
esac
