#!/bin/bash

pushd hardware
rm -rf build-sim
mkdir build-sim
pushd build-sim
# Some test tops use up to 3 host streams
/usr/bin/cmake .. -DPARCORE_NUM_DECODERS=4
make sim
