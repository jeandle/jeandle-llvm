add_llvm_component_library(LLVMJeandleTransforms
  ConstantFieldFolding.cpp
  InsertGCBarriers.cpp
  JavaOperationLower.cpp
  TLSPointerRewrite.cpp
  TypeCheckElimination.cpp

  ADDITIONAL_HEADER_DIRS
  ${LLVM_MAIN_INCLUDE_DIR}/llvm/Transforms/Jeandle

  LINK_COMPONENTS
  Analysis
  Core
  )
