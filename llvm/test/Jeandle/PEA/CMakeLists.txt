set(LLVM_TEST_DEPENDS
  JeandleAnalysis
  PEAPrinterPass
)

add_lit_testsuite(check-pea "Running PEA tests"
  ${CMAKE_CURRENT_SOURCE_DIR}/PEA
  DEPENDS ${LLVM_TEST_DEPENDS}
)