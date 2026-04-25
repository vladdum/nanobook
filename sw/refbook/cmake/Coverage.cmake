# Coverage.cmake — gcov flags and a `coverage` custom target.
message(STATUS "refbook: coverage instrumentation enabled (gcov)")
add_compile_options(--coverage -O0 -g)
add_link_options(--coverage)

find_program(LCOV lcov)
find_program(GENHTML genhtml)

# When the user invokes a non-default GCC (e.g., CC=gcc-12 on a system whose
# /usr/bin/gcov is from a different gcc version), pass the matching gcov to
# lcov, otherwise lcov errors with "Incompatible GCC/GCOV version".
set(LCOV_GCOV_FLAGS)
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU"
   AND CMAKE_CXX_COMPILER_VERSION MATCHES "^([0-9]+)\\.")
  list(APPEND LCOV_GCOV_FLAGS --gcov-tool gcov-${CMAKE_MATCH_1})
  message(STATUS "refbook: lcov will use gcov-${CMAKE_MATCH_1} (g++ ${CMAKE_CXX_COMPILER_VERSION})")
endif()

if(LCOV AND GENHTML)
  # Note: --no-external is omitted because lcov 2.0 strips files outside the
  # source tree before --include patterns apply, leaving nothing to match.
  # The --include patterns alone are sufficient to restrict scope to refbook.
  add_custom_target(refbook_coverage
    COMMAND ${LCOV}   --capture --directory ${CMAKE_BINARY_DIR}
                      --output-file ${CMAKE_BINARY_DIR}/lcov.info
                      ${LCOV_GCOV_FLAGS}
                      --include '${CMAKE_SOURCE_DIR}/src/*'
                      --include '${CMAKE_SOURCE_DIR}/include/*'
    COMMAND ${GENHTML} ${CMAKE_BINARY_DIR}/lcov.info
                      --output-directory ${CMAKE_BINARY_DIR}/coverage_report
    COMMAND ${LCOV}    --summary ${CMAKE_BINARY_DIR}/lcov.info > ${CMAKE_BINARY_DIR}/coverage_summary.txt
    DEPENDS refbook_tests
    COMMENT "refbook: generating gcov/lcov report")
endif()
