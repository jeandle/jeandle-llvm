//===- JeandleGCNarrowOopAnnotation.cpp -----------------------------------===//
//
// This pass runs after RewriteStatepointsForGC. It inspects each statepoint's
// gc-live bundle and builds a bitmask indicating which gc pointers are
// narrowoops (address space 3). The bitmask is appended to the deopt bundle
// as an i64 constant. The JDK-side parse_stackmap reads this bitmask after
// consuming deopt args, and uses it to call set_narrowoop instead of set_oop.
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IRBuilder.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Statepoint.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/Transforms/Jeandle/JeandleGCNarrowOopAnnotation.h"
 
using namespace llvm;
 

static unsigned getGCLiveSize(const GCStatepointInst *SP) {
  auto B = SP->getOperandBundle(LLVMContext::OB_gc_live);
  return B ? B->Inputs.size() : 0;
}

static SmallVector<uint64_t, 1> computeNarrowOopMask(const GCStatepointInst *SP) {
  SmallVector<uint64_t, 1> Mask;
  unsigned N = getGCLiveSize(SP);
  if (N == 0)
    return Mask;
 
  unsigned ChunkCount = (N + 63) / 64;
  Mask.resize(ChunkCount, 0);
 
  for (auto [Idx, U] : llvm::enumerate(SP->gc_live())) {
    auto *PT = dyn_cast<PointerType>(U.get()->getType());
    if (PT && PT->getAddressSpace() == jeandle::AddrSpace::NarrowOopAddrSpace)
      Mask[Idx / 64] |= (1ULL << (Idx % 64));
  }
  return Mask;
}
 
/// Rebuild SP with the narrow-oop Mask appended to its deopt operand
/// bundle. If no deopt bundle exists, one is synthesized. All other bundles
/// are passed through unchanged.
static CallBase *rebuildWithMask(GCStatepointInst *SP,
                                 ArrayRef<uint64_t> Mask) {
  LLVMContext &Ctx = SP->getContext();
  Type *I64Ty = Type::getInt64Ty(Ctx);
 
  SmallVector<OperandBundleDef, 4> NewBundles;
  bool SawDeopt = false;
 
  auto appendMask = [&](SmallVectorImpl<Value *> &Inputs) {
    for (uint64_t Chunk : Mask)
      Inputs.push_back(ConstantInt::get(I64Ty, Chunk));
  };
 
  for (unsigned I = 0, E = SP->getNumOperandBundles(); I < E; ++I) {
    auto B = SP->getOperandBundleAt(I);
 
    SmallVector<Value *, 16> Inputs;
    Inputs.reserve(B.Inputs.size() +
                   (B.getTagID() == LLVMContext::OB_deopt ? Mask.size() : 0));
    for (const Use &U : B.Inputs)
      Inputs.push_back(U.get());
 
    if (B.getTagID() == LLVMContext::OB_deopt) {
      SawDeopt = true;
      appendMask(Inputs);
    }
    NewBundles.emplace_back(std::string(B.getTagName()), std::move(Inputs));
  }
 
  // If no deopt bundle existed, synthesize one holding just the mask.
  if (!SawDeopt) {
    SmallVector<Value *, 4> Inputs;
    appendMask(Inputs);
    NewBundles.emplace_back("deopt", std::move(Inputs));
  }
 
  CallBase *NewSP = CallBase::Create(SP, NewBundles, SP->getIterator());
  NewSP->setAttributes(SP->getAttributes());

  // Preserve all metadata from the original statepoint.
  SmallVector<std::pair<unsigned, MDNode *>, 4> MDs;
  SP->getAllMetadata(MDs);
  for (auto &[Kind, MD] : MDs)
    NewSP->setMetadata(Kind, MD);

  NewSP->takeName(SP);
  return NewSP;
}

/// Annotate all statepoints with narrow-oop bitmasks.
/// Returns true if the IR was modified.
static bool annotateFunction(Function &F) {
  SmallVector<GCStatepointInst *, 16> Statepoints;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (auto *SP = dyn_cast<GCStatepointInst>(&I))
        Statepoints.push_back(SP);

  bool Changed = false;
  for (GCStatepointInst *SP : Statepoints) {
    SmallVector<uint64_t, 1> Mask = computeNarrowOopMask(SP);
    if (Mask.empty())
      continue;

    CallBase *NewSP = rebuildWithMask(SP, Mask);
    SP->replaceAllUsesWith(NewSP);
    SP->eraseFromParent();
    Changed = true;
  }

  return Changed;
}

PreservedAnalyses JeandleGCNarrowOopAnnotation::run(Function &F, FunctionAnalysisManager &AM) {
  if (!annotateFunction(F))
    return PreservedAnalyses::all();
  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
