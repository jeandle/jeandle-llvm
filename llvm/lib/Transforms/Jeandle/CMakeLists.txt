add_llvm_component_library(LLVMJeandleTransforms
  InsertGCBarriers.cpp
  JavaOperationLower.cpp
  TLSPointerRewrite.cpp

  ADDITIONAL_HEADER_DIRS
  ${LLVM_MAIN_INCLUDE_DIR}/llvm/Transforms/Jeandle

  LINK_COMPONENTS
  Core
  )
