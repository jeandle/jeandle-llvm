//===- JeandleGCNarrowOopAnnotation.h -------------------------------------===//
//
// Pass to annotate statepoint gc-live pointers with narrowoop information.
// Runs after RewriteStatepointsForGC.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_TRANSFORMS_JEANDLE_JEANDLEGCNARROWOOPANNOTATION_H
#define LLVM_TRANSFORMS_JEANDLE_JEANDLEGCNARROWOOPANNOTATION_H

#include "llvm/IR/PassManager.h"

namespace llvm {

class JeandleGCNarrowOopAnnotation : public PassInfoMixin<JeandleGCNarrowOopAnnotation> {
public:
  PreservedAnalyses run(Function &F, FunctionAnalysisManager &AM);
};

} // end namespace llvm

#endif // LLVM_TRANSFORMS_JEANDLE_JEANDLEGCNARROWOOPANNOTATION_H
