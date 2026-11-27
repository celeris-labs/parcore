cmake_minimum_required(VERSION 3.0)
project(parcore)

set(CYT_DIR ${CMAKE_SOURCE_DIR}/../libstf/coyote)
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} ${CYT_DIR}/cmake)

find_package(CoyoteHW REQUIRED)

set(COMP_CORES 64)
set(N_REGIONS 1)
set(BUILD_OPT 1)
set(EN_STRM 1)
set(PARCORE_NUM_DECODERS 1 CACHE STRING "Number of ColumnChunkDecoders, each with its own host stream")
set(N_STRM_AXI ${PARCORE_NUM_DECODERS})
set(FDEV_NAME u55c)
set(DEBUG 1)
# Enable 1 GiB huge pages in the TLB
set(TLBL_BITS 30)

validation_checks_hw()

set(VFPGA_TOP "" CACHE STRING "vFPGA top to build instead of src/vfpga_top.svh, relative to hardware/ (e.g. unit-tests/vfpga_tops/run_decoder_test.sv)")

set(VFPGA_SRC_DIRS "src ../libstf/hardware/src ../vhsnunzip/src")

# Coyote takes the vFPGA top from the first source directory, so a custom top is copied into its own
# directory in the build tree that is put in front of the other source directories.
if(VFPGA_TOP)
    get_filename_component(VFPGA_TOP_FILE ${VFPGA_TOP} ABSOLUTE BASE_DIR ${CMAKE_SOURCE_DIR})
    if(NOT EXISTS ${VFPGA_TOP_FILE})
        message(FATAL_ERROR "VFPGA_TOP ${VFPGA_TOP_FILE} does not exist.")
    endif()
    configure_file(${VFPGA_TOP_FILE} ${CMAKE_BINARY_DIR}/vfpga_top/vfpga_top.svh COPYONLY)
    file(RELATIVE_PATH VFPGA_TOP_DIR ${CMAKE_SOURCE_DIR} ${CMAKE_BINARY_DIR}/vfpga_top)
    set(VFPGA_SRC_DIRS "${VFPGA_TOP_DIR} ${VFPGA_SRC_DIRS}")
endif()

load_apps (
    VFPGA_C0_0 "${VFPGA_SRC_DIRS}"
)

create_hw()
