cmake_minimum_required(VERSION 3.20)
project(cu2mini C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(LLVM REQUIRED CONFIG)
find_package(Clang REQUIRED CONFIG)

message(STATUS "LLVM ${LLVM_PACKAGE_VERSION} @ ${LLVM_DIR}")
message(STATUS "Clang @ ${CLANG_CMAKE_DIR}")

include_directories(${LLVM_INCLUDE_DIRS} ${CLANG_INCLUDE_DIRS})
separate_arguments(LLVM_DEFS NATIVE_COMMAND ${LLVM_DEFINITIONS})
add_definitions(${LLVM_DEFS})

add_executable(cu2mini cu2mini.cpp)
# Arch/Clang22 ships tooling only inside libclang-cpp (no component static libs).
target_link_libraries(cu2mini PRIVATE clang-cpp LLVM)
