#!/bin/bash

set -e -x -o pipefail

# test for successful release build
dub build --combined -b release --compiler=$DC

# test for successful 32-bit build
if [ "$DC" == "dmd" ]; then
	dub build --combined --arch=x86
fi

dub test --combined --compiler=$DC

if [ ${BUILD_EXAMPLE=1} -eq 1 ]; then
    for ex in $(\ls -1 examples/); do
        echo "[INFO] Building example $ex"
        (cd examples/$ex && dub build --compiler=$DC && dub clean)
    done
fi
if [ ${RUN_TEST=1} -eq 1 ]; then
    for ex in `\ls -1 tests/*.d`; do
        echo "[INFO] Running test $ex"
        dub --temp-build --compiler=$DC --single $ex
    done
fi
