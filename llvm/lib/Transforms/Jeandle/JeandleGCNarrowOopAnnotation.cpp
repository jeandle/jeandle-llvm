//===- JeandleGCNarrowOopAnnotation.cpp -----------------------------------===//
//
// This pass runs after RewriteStatepointsForGC. It inspects each statepoint's
// gc-live bundle and builds a bitmask indicating which gc pointers are
// narrowoops (address space 3). The bitmask is appended to the deopt bundle
// as an i64 constant. The JDK-side parse_stackmap reads this bitmask after
// consuming deopt args, and uses it to call set_narrowoop instead of set_oop.
//
//===----------------------------------------------------------------------===//

#include "llvm/Transforms/Jeandle/JeandleGCNarrowOopAnnotation.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/GlobalVariable.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/Statepoint.h"
#include "llvm/Transforms/Utils/ModuleUtils.h"

using namespace llvm;

#define DEBUG_TYPE "jeandle-gc-narrowoop-annotation"

namespace {

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

  bool HasNarrowOop = false;
  for (auto [Idx, U] : llvm::enumerate(SP->gc_live())) {
    auto *PT = dyn_cast<PointerType>(U.get()->getType());
    if (PT && PT->getAddressSpace() == jeandle::AddrSpace::NarrowOopAddrSpace) {
      Mask[Idx / 64] |= (1ULL << (Idx % 64));
      HasNarrowOop = true;
    }
  }

  if (!HasNarrowOop)
    Mask.clear();

  return Mask;
}

// [patchpoint_id, chunk_count, mask_chunk_0, mask_chunk_1, ...]
static void emitMaskSection(Module &M,
                            SmallVectorImpl<uint64_t> &TableData) {
  if (TableData.empty())
    return;

  LLVMContext &Ctx = M.getContext();
  Type *I64Ty = Type::getInt64Ty(Ctx);

  SmallVector<Constant *, 64> Elts;
  for (uint64_t V : TableData)
    Elts.push_back(ConstantInt::get(I64Ty, V));

  ArrayType *ArrTy = ArrayType::get(I64Ty, Elts.size());
  Constant *Init = ConstantArray::get(ArrTy, Elts);

  auto *GV = new GlobalVariable(
      M, ArrTy, /*isConstant=*/true, GlobalValue::ExternalLinkage,
      Init, "jeandle_narrowoop_mask_table");
  GV->setSection(".jeandle_narrowoop_masks");
  GV->setAlignment(Align(8));
  GV->setUnnamedAddr(GlobalValue::UnnamedAddr::Global);

  appendToUsed(M, {GV});
}

static bool appendMaskIDToDeopt(GCStatepointInst *SP, uint64_t MaskID) {
  LLVMContext &Ctx = SP->getContext();
  Type *I64Ty = Type::getInt64Ty(Ctx);

  SmallVector<OperandBundleDef, 4> NewBundles;
  bool SawDeopt = false;

  for (unsigned I = 0, E = SP->getNumOperandBundles(); I < E; ++I) {
    auto B = SP->getOperandBundleAt(I);

    SmallVector<Value *, 16> Inputs;
    for (const Use &U : B.Inputs)
      Inputs.push_back(U.get());

    if (B.getTagID() == LLVMContext::OB_deopt) {
      SawDeopt = true;
      Inputs.push_back(ConstantInt::get(I64Ty, MaskID));
    }
    NewBundles.emplace_back(std::string(B.getTagName()), std::move(Inputs));
  }

  if (!SawDeopt) {
    SmallVector<Value *, 1> Inputs;
    Inputs.push_back(ConstantInt::get(I64Ty, MaskID));
    NewBundles.emplace_back("deopt", std::move(Inputs));
  }

  CallBase *NewSP = CallBase::Create(SP, NewBundles, SP->getIterator());
  NewSP->setAttributes(SP->getAttributes());

  SmallVector<std::pair<unsigned, MDNode *>, 4> MDs;
  SP->getAllMetadata(MDs);
  for (auto &[Kind, MD] : MDs)
    NewSP->setMetadata(Kind, MD);

  NewSP->takeName(SP);
  SP->replaceAllUsesWith(NewSP);
  SP->eraseFromParent();
  return true;
}

} // end anonymous namespace

PreservedAnalyses JeandleGCNarrowOopAnnotation::run(Function &F,
                                                     FunctionAnalysisManager &AM) {
  if (!F.hasFnAttribute("use-compressed-oops"))
    return PreservedAnalyses::all();

  SmallVector<uint64_t, 64> TableData;
  uint64_t NextMaskID = 1;

  SmallVector<GCStatepointInst *, 16> Statepoints;
  for (BasicBlock &BB : F)
    for (Instruction &I : BB)
      if (auto *SP = dyn_cast<GCStatepointInst>(&I))
        Statepoints.push_back(SP);

  if (Statepoints.empty())
    return PreservedAnalyses::all();

  bool Changed = false;
  bool HasAnyNarrowOop = false;

  for (GCStatepointInst *SP : Statepoints) {
    SmallVector<uint64_t, 1> Mask = computeNarrowOopMask(SP);

    uint64_t MaskID = 0;
    if (!Mask.empty()) {
      MaskID = NextMaskID++;
      // [mask_id, chunk_count, chunks...]
      TableData.push_back(MaskID);
      TableData.push_back(Mask.size());
      for (uint64_t Chunk : Mask)
        TableData.push_back(Chunk);
      HasAnyNarrowOop = true;
    }

    Changed |= appendMaskIDToDeopt(SP, MaskID);
  }

  if (HasAnyNarrowOop)
    emitMaskSection(*F.getParent(), TableData);

  if (!Changed)
    return PreservedAnalyses::all();

  PreservedAnalyses PA;
  PA.preserveSet<CFGAnalyses>();
  return PA;
}
