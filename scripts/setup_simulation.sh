#!/bin/bash

pushd hardware
rm -rf build-sim
mkdir build-sim
pushd build-sim
# Simulate 4 decoders: some test tops use up to 3 host streams, and vfpga_top_test covers decoders
# sharing the output writers
/usr/bin/cmake .. -DPARCORE_NUM_DECODERS=4
make sim
