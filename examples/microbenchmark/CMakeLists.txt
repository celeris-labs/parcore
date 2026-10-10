cmake_minimum_required(VERSION 3.10)
project(microbenchmark)

add_executable(microbenchmark main.cpp)

option(ENABLE_SIMULATION "Include the simulation version of Coyote" OFF)

if (ENABLE_SIMULATION)
  add_subdirectory(../../libstf/coyote/sim/sw coyote)
  target_compile_definitions(microbenchmark PRIVATE ENABLE_SIMULATION)
else ()
  add_subdirectory(../../libstf/coyote/sw coyote)
endif ()

target_link_libraries(microbenchmark PRIVATE Coyote)
target_include_directories(microbenchmark PRIVATE ${COYOTE_INCLUDE_DIRS})

add_subdirectory(../../libstf/software libstf)
target_link_libraries(microbenchmark PUBLIC libstf)
target_include_directories(microbenchmark PRIVATE ${LIBSTF_INCLUDE_DIRS})

set(PARCORE_WITHOUT_ARROW OFF)
add_subdirectory(../../software parcore)
target_link_libraries(microbenchmark PUBLIC parcore)
target_include_directories(microbenchmark PRIVATE ${PARCORE_INCLUDE_DIRS})

find_package(Boost REQUIRED COMPONENTS program_options)
target_link_libraries(microbenchmark PUBLIC Boost::program_options)
target_include_directories(microbenchmark PUBLIC ${ARROW_INCLUDE_DIRS})

find_package(Arrow REQUIRED)
find_package(Parquet REQUIRED)
target_link_libraries(microbenchmark PRIVATE Arrow::arrow_shared Parquet::parquet_shared)
target_include_directories(microbenchmark PRIVATE ${ARROW_INCLUDE_DIRS})

