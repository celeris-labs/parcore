cmake_minimum_required(VERSION 3.10)
project(readparquet)

add_executable(readparquet main.cpp)

option(ENABLE_SIMULATION "Include the simulation version of Coyote" OFF)

# Coyote lives inside the libstf submodule. The older examples still point at
# ../../coyote, which has not existed for some time.
if (ENABLE_SIMULATION)
  add_subdirectory(../../libstf/coyote/sim/sw coyote)
  target_compile_definitions(readparquet PRIVATE ENABLE_SIMULATION)
else ()
  add_subdirectory(../../libstf/coyote/sw coyote)
endif ()

add_subdirectory(../../libstf/software libstf)

set(PARCORE_WITHOUT_ARROW OFF)
add_subdirectory(../../software parcore)

# Target names are Coyote / libstf / parcore - note the lowercase parcore. Each
# exports its own include directories PUBLIC, so the COYOTE_INCLUDE_DIRS /
# LIBSTF_INCLUDE_DIRS / PARCORE_INCLUDE_DIRS variables the other examples pass
# to target_include_directories are dead: nothing sets them any more.
target_link_libraries(readparquet PRIVATE Coyote libstf parcore)

find_package(Boost REQUIRED COMPONENTS program_options)
target_link_libraries(readparquet PRIVATE Boost::program_options)

find_package(Arrow REQUIRED)
find_package(Parquet REQUIRED)
target_link_libraries(readparquet PRIVATE Arrow::arrow_shared Parquet::parquet_shared)
