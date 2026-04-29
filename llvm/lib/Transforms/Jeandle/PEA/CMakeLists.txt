add_llvm_component_library(LLVMJeandlePEATransforms
  PEATransformer.cpp
  PEATransformManager.cpp

  ADDITIONAL_HEADER_DIRS
  ${LLVM_MAIN_INCLUDE_DIR}/llvm/Transforms/Jeandle/PEA

  LINK_COMPONENTS
  Core
  Analysis
  )