#!/usr/bin/env bash
# Integration test for issue #99: open the demo project headless, run a
# script, save the project and check the saved module files.
#
#   1. round trip: open the demo and save it as A, then open A and save it as
#      B. A and B must be equal, apart from the "-- date" lines, so ET can
#      read back everything it writes. Differences between the demo files and
#      A are reported, but do not fail the test.
#   2. script: rename one device with a script, save, and check the saved
#      module has the new name and not the old one.
#
# Expects the et binary in $HOME/bin and network access to clone the demo
# project (ET_training) and the component library (ET_component_library).
set -euo pipefail

ET="$HOME/bin/et"
BEL="$HOME/git/BEL"
DEMO_DIR="$BEL/ET_training"
FAILED=0

step() { echo; echo "===== $*"; }

step "Clone the demo project and the component library"
mkdir -p "$BEL"
git clone --depth 1 https://github.com/Blunk-electronic/ET_training.git "$DEMO_DIR"
git clone --depth 1 https://github.com/Blunk-electronic/ET_component_library.git "$BEL/ET_component_library"
echo "ET_training at $(git -C "$DEMO_DIR" rev-parse --short HEAD)"
echo "ET_component_library at $(git -C "$BEL/ET_component_library" rev-parse --short HEAD)"

step "Point hard-coded library paths at the clone (see issue #54)"
# Some module files name device models by an absolute path from a developer's
# machine (/home/<user>/git/BEL/...). Link each such path to the clone.
grep -rhoE '/home/[A-Za-z0-9_.-]+/git/BEL' "$DEMO_DIR/demo" | sort -u | while read -r p; do
  if [ "$p" != "$BEL" ] && [ ! -e "$p" ]; then
    echo "linking $p -> $BEL"
    sudo mkdir -p "$(dirname "$p")"
    sudo ln -s "$BEL" "$p"
  fi
done

cd "$DEMO_DIR"

step "Test 1: round trip (open, save as A; open A, save as B; A must equal B)"
rm -rf ci_pass_a ci_pass_b
set +e
timeout 600 "$ET" --open-project demo --runmode headless --save-project-as ci_pass_a --log-level 2
rc_a=$?
rc_b=1
if [ "$rc_a" -eq 0 ] && [ -d ci_pass_a ]; then
  timeout 600 "$ET" --open-project ci_pass_a --runmode headless --save-project-as ci_pass_b --log-level 2
  rc_b=$?
fi
set -e
echo "et exit codes: first save $rc_a, second save $rc_b"
if [ "$rc_a" -ne 0 ] || [ ! -d ci_pass_a ] || [ "$rc_b" -ne 0 ] || [ ! -d ci_pass_b ]; then
  echo "FAIL: et could not save the project, or could not open its own saved copy"
  FAILED=1
else
  for f in ci_pass_a/*.mod; do
    name=$(basename "$f")
    if [ ! -f "ci_pass_b/$name" ]; then
      echo "FAIL $name is missing from the second save"
      FAILED=1
    elif diff -u <(grep -v '^-- date' "$f") <(grep -v '^-- date' "ci_pass_b/$name") > "ci_pass_$name.diff"; then
      echo "ok   $name is stable: saving it a second time changes nothing"
      rm -f "ci_pass_$name.diff"
    else
      echo "FAIL $name changed when saved a second time:"
      head -n 40 "ci_pass_$name.diff"
      FAILED=1
    fi
  done

  # For information only: what the current ET writes differently from the
  # demo files in ET_training. Format changes are expected here and do not
  # fail the test.
  echo
  echo "Report (not a failure): differences between the demo files and what this ET writes"
  for f in demo/*.mod; do
    name=$(basename "$f")
    [ -f "ci_pass_a/$name" ] || continue
    diff -u <(grep -v '^-- date' "$f") <(grep -v '^-- date' "ci_pass_a/$name") > "ci_report_$name.diff" || true
    changed=$(grep -c '^[-+][^-+]' "ci_report_$name.diff" || true)
    echo "  $name: $changed changed lines"
    if [ "$changed" -gt 0 ]; then
      grep '^[-+][^-+]' "ci_report_$name.diff" | sed 's/^\([-+]\)[[:space:]]*/\1 /' | sort | uniq -c | sort -rn | head -n 6 | sed 's/^/    /'
    fi
  done
fi

step "Test 2: script (rename device R1 to R901 in heater_driver)"
rm -rf ci_script
printf 'schematic heater_driver rename device R1 R901\n' > demo/ci_test.scr
set +e
timeout 600 "$ET" --open-project demo --runmode headless --script demo/ci_test.scr --save-project-as ci_script --log-level 2
rc=$?
set -e
rm -f demo/ci_test.scr
echo "et exit code: $rc"
saved=ci_script/heater_driver.mod
if [ "$rc" -ne 0 ] || [ ! -f "$saved" ]; then
  echo "FAIL: et did not save heater_driver.mod after the script"
  FAILED=1
else
  if grep -qE '^[[:space:]]*name R901[[:space:]]*$' "$saved"; then
    echo "ok   R901 is in the saved module"
  else
    echo "FAIL: R901 is not in the saved module"
    FAILED=1
  fi
  if grep -qE '^[[:space:]]*name R1[[:space:]]*$' "$saved"; then
    echo "FAIL: R1 is still in the saved module"
    FAILED=1
  else
    echo "ok   R1 is gone from the saved module"
  fi
fi

step "Result"
if [ "$FAILED" -ne 0 ]; then
  echo "demo test FAILED"
  exit 1
fi
echo "demo test passed"
