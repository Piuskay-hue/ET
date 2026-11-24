#!/usr/bin/env bash
# Integration test for issue #99: open the demo project headless, run a
# script, save the project and check the saved module files.
#
#   1. round trip: open the demo and save it unchanged. Every saved .mod file
#      must equal its original, apart from the "-- date" lines.
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

step "Test 1: round trip (open the demo, save it unchanged)"
rm -rf ci_roundtrip
set +e
timeout 600 "$ET" --open-project demo --runmode headless --save-project-as ci_roundtrip --log-level 2
rc=$?
set -e
echo "et exit code: $rc"
if [ "$rc" -ne 0 ] || [ ! -d ci_roundtrip ]; then
  echo "FAIL: et did not save the project"
  FAILED=1
else
  for f in demo/*.mod; do
    name=$(basename "$f")
    if [ ! -f "ci_roundtrip/$name" ]; then
      echo "FAIL: $name was not saved"
      FAILED=1
      continue
    fi
    if diff -u <(grep -v '^-- date' "$f") <(grep -v '^-- date' "ci_roundtrip/$name") > "ci_roundtrip_$name.diff"; then
      echo "ok   $name is unchanged after a round trip"
    else
      echo "FAIL $name changed after a round trip ($(grep -c '^[-+][^-+]' "ci_roundtrip_$name.diff") lines differ):"
      head -n 40 "ci_roundtrip_$name.diff"
      FAILED=1
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
