cmake_minimum_required(VERSION 3.10)
project(readfile)

add_executable(readfile main.cpp)

option(ENABLE_SIMULATION "Include the simulation version of Coyote" OFF)

if (ENABLE_SIMULATION)
  add_subdirectory(../../libstf/coyote/sim/sw coyote)
  target_compile_definitions(readfile PRIVATE ENABLE_SIMULATION)
else ()
  add_subdirectory(../../libstf/coyote/sw coyote)
endif ()

add_subdirectory(../../libstf/software libstf)

target_link_libraries(readfile PRIVATE Coyote)
target_include_directories(readfile PRIVATE ${COYOTE_INCLUDE_DIRS})

set(PARCORE_WITHOUT_ARROW OFF)
add_subdirectory(../../software parcore)
target_link_libraries(readfile PUBLIC parcore)
target_include_directories(readfile PRIVATE ${PARCORE_INCLUDE_DIRS})

target_link_libraries(readfile PUBLIC libstf)
target_include_directories(readfile PRIVATE ${LIBSTF_INCLUDE_DIRS})

find_package(Boost REQUIRED COMPONENTS program_options)
target_link_libraries(readfile PUBLIC Boost::program_options)
target_include_directories(readfile PUBLIC ${ARROW_INCLUDE_DIRS})

find_package(Arrow REQUIRED)
target_link_libraries(readfile PRIVATE Arrow::arrow_shared)
target_include_directories(readfile PRIVATE ${ARROW_INCLUDE_DIRS})
