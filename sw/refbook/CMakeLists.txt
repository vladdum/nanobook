cmake_minimum_required(VERSION 3.26)
project(refbook
  VERSION 0.1.0
  LANGUAGES CXX
  DESCRIPTION "Nanobook reference L3 order book (C++17 golden model)")

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE RelWithDebInfo CACHE STRING "" FORCE)
endif()

option(REFBOOK_BUILD_TESTS     "Build GoogleTest suite"      ON)
option(REFBOOK_BUILD_BENCH     "Build Google Benchmark suite" OFF)
option(REFBOOK_BUILD_PYTHON    "Build pybind11 module"       OFF)
option(REFBOOK_COVERAGE        "Enable gcov coverage flags"  OFF)

if(REFBOOK_COVERAGE)
  include(cmake/Coverage.cmake)
endif()

add_library(refbook_core STATIC)
target_sources(refbook_core PRIVATE
  src/order_pool.cpp
  src/price_ladder.cpp
  src/sliding_window.cpp
  src/book.cpp
)
target_include_directories(refbook_core PUBLIC include)
target_compile_options(refbook_core PRIVATE -Wall -Wextra -Wpedantic -Werror)

include(FetchContent)

if(REFBOOK_BUILD_TESTS)
  enable_testing()
  FetchContent_Declare(
    googletest
    URL      https://github.com/google/googletest/archive/v1.15.2.tar.gz
    URL_HASH SHA256=7b42b4d6ed48810c5362c265a17faebe90dc2373c885e5216439d37927f02926
  )
  set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(googletest)
  add_executable(refbook_tests)
  target_sources(refbook_tests PRIVATE
    test/test_tob_delta.cpp
    test/test_book_event.cpp
    test/test_order_pool.cpp
    test/test_order_map.cpp
    test/test_price_ladder.cpp
    test/test_sliding_window.cpp
    test/test_book_add.cpp
    test/test_book_delete.cpp
    test/test_book_cancel_exec.cpp
    test/test_book_multisym.cpp
    test/test_properties.cpp
    test/test_reproducibility.cpp
    test/test_book_coverage.cpp
    test/test_pcap_replay.cpp
  )
  target_link_libraries(refbook_tests PRIVATE refbook_core GTest::gtest_main)
  include(GoogleTest)
  gtest_discover_tests(refbook_tests)
  configure_file(
    ${CMAKE_CURRENT_SOURCE_DIR}/test/reproducibility_expected.sha256
    ${CMAKE_CURRENT_BINARY_DIR}/test/reproducibility_expected.sha256
    COPYONLY)
endif()

if(REFBOOK_BUILD_BENCH)
  FetchContent_Declare(
    benchmark
    URL      https://github.com/google/benchmark/archive/v1.9.0.tar.gz
    URL_HASH SHA256=35a77f46cc782b16fac8d3b107fbfbb37dcd645f7c28eee19f3b8e0758b48994
  )
  set(BENCHMARK_ENABLE_TESTING OFF CACHE BOOL "" FORCE)
  FetchContent_MakeAvailable(benchmark)
  add_executable(refbook_bench bench/bench_step.cpp)
  target_link_libraries(refbook_bench PRIVATE refbook_core benchmark::benchmark)
endif()

if(REFBOOK_BUILD_PYTHON)
  add_subdirectory(${CMAKE_SOURCE_DIR}/../../third_party/pybind11 pybind11_build)
  pybind11_add_module(refbook bindings/pybind_module.cpp)
  target_link_libraries(refbook PRIVATE refbook_core)
  install(TARGETS refbook LIBRARY DESTINATION .)
endif()
