//===- PartialEscapeAnalysis.cpp - Partial Escape Analysis Implementation ===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/Analysis/Jeandle/PartialEscapeAnalysis.h"
#include "llvm/ADT/PostOrderIterator.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Constants.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/InstIterator.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/Jeandle/JeandleUtil.h"
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/Support/CommandLine.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

#define DEBUG_TYPE "partial-escape-analysis"

using namespace llvm;
using namespace jeandle;

// Command line options for Partial Escape Analysis
static cl::opt<bool> EnablePEA(
    "jeandle-pea",
    cl::desc("Enable partial escape analysis optimization"),
    cl::init(true));

static cl::opt<uint32_t> PEAMaxArrayLength(
    "jeandle-pea-max-array-length",
    cl::desc("Maximum array length for PEA to process (0=dynamic, <=32=optimizable, >32=large)"),
    cl::init(32));

bool PEAConfig::Enabled = EnablePEA;
uint32_t PEAConfig::MaxArrayLength = PEAMaxArrayLength;

//===----------------------------------------------------------------------===//
// PEAResult Implementation - Update/query aliases and states
//===----------------------------------------------------------------------===//

ProgramPointState *PEAResult::createInstState(Instruction *Inst) {
  auto It = InstStates.find(Inst);
  if (It != InstStates.end())
    return It->second.get();

  auto S = std::make_unique<ProgramPointState>();
  ProgramPointState *Ptr = S.get();
  InstStates[Inst] = std::move(S);
  return Ptr;
}

ProgramPointState *PEAResult::createBlockState(BasicBlock *BB) {
  auto It = BlockStates.find(BB);
  if (It != BlockStates.end())
    return It->second.get();

  auto S = std::make_unique<ProgramPointState>();
  ProgramPointState *Ptr = S.get();
  BlockStates[BB] = std::move(S);
  return Ptr;
}

AllocationObject *PEAResult::getAllocationObject(AllocID Id) const {
  if (Id < Allocations.size())
    return Allocations[Id].get();
  return nullptr;
}

AliasInfo PEAResult::getAliasInfo(Value *V) const {
  auto It = Alias.find(V);
  return It != Alias.end() ? It->second : AliasInfo();
}

void PEAResult::createAlias(Value *V, AliasInfo P) {
  Alias[V] = P;
}

AllocationObject *PEAResult::createAllocationObject(Instruction *Source, bool IsArray) {
  AllocID NewId = Allocations.size();

  std::unique_ptr<AllocationObject> Obj;
  if (IsArray) {
    Obj = std::make_unique<ArrayAllocationObject>(NewId, Source);
  } else {
    Obj = std::make_unique<AllocationObject>(NewId, Source);
  }

  Allocations.push_back(std::move(Obj));
  return Allocations.back().get();
}

AllocationObject *PEAResult::createVirtualAllocationObject(PHINode *Phi) {
  AllocID NewId = Allocations.size();
  auto Obj = std::make_unique<VirtualAllocationObject>(NewId, Phi);
  Allocations.push_back(std::move(Obj));
  return Allocations.back().get();
}

ProgramPointState *PEAResult::getInstState(Instruction *Inst) const {
  auto It = InstStates.find(Inst);
  return It != InstStates.end() ? It->second.get() : nullptr;
}

ProgramPointState *PEAResult::getBlockState(BasicBlock *BB) const {
  auto It = BlockStates.find(BB);
  return It != BlockStates.end() ? It->second.get() : nullptr;
}

const AllocationState *PEAResult::getAllocationStateAt(Instruction *I, AllocID AllocId) const {
  if (hasState(I)) {
    return getInstState(I)->getAllocState(AllocId);
  }

  BasicBlock *BB = I->getParent();
  Instruction *LastStateInst = nullptr;
  for (Instruction &Prev : *BB) {
    if (&Prev == I) break;
    if (hasState(&Prev)) {
      LastStateInst = &Prev;
    }
  }

  if (LastStateInst) {
    return getInstState(LastStateInst)->getAllocState(AllocId);
  }

  if (hasBlockState(BB)) {
    return getBlockState(BB)->getAllocState(AllocId);
  }

  return nullptr;
}

SmallVector<Instruction *> PEAResult::getEscapePoints(AllocID AllocId) const {
  SmallVector<Instruction *> Points;
  for (const auto &[Inst, S] : InstStates) {
    if (S->getEscapeState(AllocId) == EscapeState::GlobalEscape)
      Points.push_back(Inst);
  }
  return Points;
}

SmallVector<Instruction *> PEAResult::getAllEscapePoints() const {
  SmallVector<Instruction *> Points;
  for (const auto &Alloc : Allocations) {
    if (Alloc->getId() == 0) continue;
    auto AllocPoints = getEscapePoints(Alloc->getId());
    for (Instruction *I : AllocPoints) {
      if (!llvm::is_contained(Points, I))
        Points.push_back(I);
    }
  }
  return Points;
}

SmallVector<AllocationObject *> PEAResult::getTrackedAllocations() const {
  SmallVector<AllocationObject *> Result;
  for (const auto &Alloc : Allocations) {
    if (Alloc->getId() != 0)
      Result.push_back(Alloc.get());
  }
  return Result;
}

SmallVector<LazyObjectBundle, 4>
PEAResult::buildLazyObjectBundles(Instruction *DeoptPoint) const {
  // TODO(PEA-Deopt): Implement lazy_object bundle generation
  // This will be implemented in the optimization pass (PEATransformer)
  // Steps:
  // 1. Identify all NoEscape allocations referenced at DeoptPoint
  // 2. For each allocation, build LazyObjectBundle with:
  //    - AllocId
  //    - Klass (from AllocationNode::getKlass())
  //    - All field values from AllocationState
  //    - Handle nested object references (ReferencedAllocId)
  // 3. Return all bundles
  return SmallVector<LazyObjectBundle, 4>();
}

VirtualPhiNode *PEAResult::createVirtualPhiNode(AllocID AllocId, uint32_t Offset, BasicBlock *MergeBB) {
  return new VirtualPhiNode(AllocId, Offset, MergeBB);
}

//===----------------------------------------------------------------------===//
// VirtualPhiNode Implementation
//===----------------------------------------------------------------------===//

PHINode *VirtualPhiNode::createPHIIR(Type *FieldType) const {
  BasicBlock *BB = MergeBB;
  std::string Name = "vphi_" + std::to_string(AllocId) + "_" + std::to_string(Offset);
  PHINode *Phi = PHINode::Create(FieldType, getNumInputs(), Name, BB->getFirstNonPHIOrDbg());

  for (const auto &[PredBB, Val] : Inputs) {
    Phi->addIncoming(Val, PredBB);
  }

  return Phi;
}

//===----------------------------------------------------------------------===//
// AllocationState Implementation
//===----------------------------------------------------------------------===//

void AllocationState::mergeFrom(const SmallVector<const AllocationState*> &PredStates,
                                const SmallVector<BasicBlock*> &PredBBs,
                                AllocID AllocId,
                                PEAResult &Result,
                                BasicBlock *MergeBB) {
  if (PredStates.empty()) return;

  // Step 1: Merge EscapeState
  ES = PredStates[0]->ES;
  for (size_t i = 1; i < PredStates.size(); i++) {
    ES = std::max(ES, PredStates[i]->ES);
  }

  // Step 2: Check LockCount consistency
  uint32_t FirstLockCount = PredStates[0]->LockCount;
  for (size_t i = 1; i < PredStates.size(); i++) {
    if (PredStates[i]->LockCount != FirstLockCount) {
      ES = EscapeState::GlobalEscape;
      return;
    }
  }
  LockCount = FirstLockCount;

  // Step 3: Collect all field offsets (union of all predecessors)
  DenseSet<uint32_t> AllOffsets;
  for (const AllocationState *PredState : PredStates) {
    for (const auto &[Offset, FI] : PredState->Fields) {
      AllOffsets.insert(Offset);
    }
  }

  // Step 4: Merge each field
  for (uint32_t Offset : AllOffsets) {
    // Collect all values for this offset from predecessors
    SmallVector<Value*> Values;
    SmallVector<BasicBlock*> BBs;
    Type *FieldType = nullptr;
    bool IsOop = false;
    bool AllHaveField = true;

    for (size_t i = 0; i < PredStates.size(); i++) {
      const AllocationState *PredState = PredStates[i];
      if (PredState->hasField(Offset)) {
        const FieldInfo *FI = PredState->getField(Offset);
        Values.push_back(FI->StoredValue);
        BBs.push_back(PredBBs[i]);
        if (!FieldType) {
          FieldType = FI->FieldType;
          IsOop = FI->IsOop;
        }
      } else {
        Values.push_back(nullptr);
        BBs.push_back(PredBBs[i]);
        AllHaveField = false;
      }
    }

    // Check if all values are identical
    Value *FirstValue = Values[0];
    bool AllSame = true;
    for (size_t i = 1; i < Values.size(); i++) {
      if (Values[i] != FirstValue) {
        AllSame = false;
        break;
      }
    }

    if (AllSame && AllHaveField) {
      // All values identical - use the value directly
      Fields[Offset] = FieldInfo(FirstValue, FieldType, IsOop);
    } else {
      // Values differ or some missing - create VirtualPhiNode
      VirtualPhiNode *Phi = Result.createVirtualPhiNode(AllocId, Offset, MergeBB);
      for (size_t i = 0; i < Values.size(); i++) {
        Phi->addInput(BBs[i], Values[i]);
      }
      Fields[Offset] = FieldInfo(Phi, FieldType, IsOop);
    }
  }
}

bool AllocationState::operator==(const AllocationState &Other) const {
  if (ES != Other.ES) return false;
  if (LockCount != Other.LockCount) return false;

  if (Fields.size() != Other.Fields.size()) return false;
  for (const auto &[Offset, FI] : Fields) {
    auto It = Other.Fields.find(Offset);
    if (It == Other.Fields.end()) return false;
    const FieldInfo &OtherFI = It->second;
    if (FI.StoredValue != OtherFI.StoredValue ||
        FI.FieldType != OtherFI.FieldType ||
        FI.IsOop != OtherFI.IsOop)
      return false;
  }

  return true;
}

//===----------------------------------------------------------------------===//
// ProgramPointState Implementation
//===----------------------------------------------------------------------===//

void ProgramPointState::mergeFrom(const SmallVector<ProgramPointState*> &PredStates,
                                  const SmallVector<BasicBlock*> &PredBBs,
                                  PEAResult &Result,
                                  BasicBlock *MergeBB) {
  assert(!PredStates.empty());

  // Find intersection of all AllocIDs across predecessors
  DenseSet<AllocID> CommonAllocIds;
  for (const auto &[AllocId, AS] : PredStates[0]->AllocationStates) {
    CommonAllocIds.insert(AllocId);
  }

  for (size_t i = 1; i < PredStates.size(); i++) {
    DenseSet<AllocID> ThisAllocIds;
    for (const auto &[AllocId, AS] : PredStates[i]->AllocationStates) {
      ThisAllocIds.insert(AllocId);
    }
    DenseSet<AllocID> NewCommon;
    for (AllocID Id : CommonAllocIds) {
      if (ThisAllocIds.contains(Id)) {
        NewCommon.insert(Id);
      }
    }
    CommonAllocIds = NewCommon;
  }

  // Merge allocation states for each AllocID in intersection
  for (AllocID AllocId : CommonAllocIds) {
    SmallVector<const AllocationState*> PredAllocStates;
    for (ProgramPointState *PredState : PredStates) {
      PredAllocStates.push_back(PredState->getAllocState(AllocId));
    }

    AllocationStates[AllocId].mergeFrom(PredAllocStates, PredBBs, AllocId, Result, MergeBB);
  }
}

std::unique_ptr<ProgramPointState> ProgramPointState::copy() const {
  return std::make_unique<ProgramPointState>(*this);
}

bool ProgramPointState::operator==(const ProgramPointState &Other) const {
  if (AllocationStates.size() != Other.AllocationStates.size()) return false;
  for (const auto &[AllocId, AS] : AllocationStates) {
    auto It = Other.AllocationStates.find(AllocId);
    if (It == Other.AllocationStates.end() || !(It->second == AS)) return false;
  }

  return true;
}

//===----------------------------------------------------------------------===//
// Helper Functions
//===----------------------------------------------------------------------===//

static uint32_t getObjectSize(AllocationObject *Alloc) {
  if (Alloc->getSource()) {
    CallInst *Call = dyn_cast<CallInst>(Alloc->getSource());
    if (Call && Call->getCalledFunction()) {
      StringRef Name = Call->getCalledFunction()->getName();
      if (Name == "jeandle.new_instance" || Name == "jeandle.newarray") {
        if (auto *SizeConst = dyn_cast<ConstantInt>(Call->getArgOperand(1))) {
          return SizeConst->getZExtValue();
        }
      }
    }
  }
  return 0;
}

static bool hasEscapedAllocation(const SmallVector<AllocID> &allocIds,
                                 ProgramPointState *State) {
  for (AllocID AllocId : allocIds) {
    if (AllocId != 0 &&
        State->getEscapeState(AllocId) == EscapeState::GlobalEscape)
      return true;
  }
  return false;
}

/// Check if multiple allocations can be merged into a VirtualAllocationObject.
///
/// This function is called when a PHI node has multiple incoming allocations.
/// If they are compatible, we create a single VirtualAllocationObject to represent
/// the merged object, enabling scalar replacement across different control flow paths.
///
/// Compatibility criteria:
/// 1. All allocations must be NoEscape (not GlobalEscape)
/// 2. All allocations must have the same object size
/// 3. All allocations must have the same LockCount
/// 4. All allocations must have consistent field type information
/// 5. All allocations must have the same set of field offsets
static bool checkAllocationCompatibility(
    const SmallVector<AllocID> &allocIds,
    ProgramPointState *State,
    const DenseMap<BasicBlock*, std::unique_ptr<ProgramPointState>> &BlockOutStates,
    const PHINode &Phi,
    PEAResult &Result) {

  if (allocIds.empty()) return true;

  // Convert AllocIDs to AllocationObjects (needed for getObjectSize)
  SmallVector<AllocationObject*> allocs;
  for (AllocID Id : allocIds) {
    AllocationObject *Alloc = Result.getAllocationObject(Id);
    if (Alloc) allocs.push_back(Alloc);
  }

  // Check 1: All allocations must be NoEscape
  for (AllocationObject *alloc : allocs) {
    if (State->getEscapeState(alloc->getId()) != EscapeState::NoEscape)
      return false;
  }

  // Check 2: All allocations must have the same object size
  uint32_t firstSize = getObjectSize(allocs[0]);
  for (AllocationObject *alloc : allocs) {
    if (getObjectSize(alloc) != firstSize)
      return false;
  }

  // Initialize tracking for LockCount and field information
  int32_t firstLockCount = 0;
  bool firstLockCountSet = false;

  // fieldTypeInfo: maps offset -> (FieldType, IsOop) for consistency check
  DenseMap<uint32_t, std::pair<Type*, bool>> fieldTypeInfo;

  // allocFieldSets: maps allocation -> set of field offsets it has
  DenseMap<AllocationObject*, DenseSet<uint32_t>> allocFieldSets;

  // Check each PHI incoming value
  for (unsigned i = 0; i < Phi.getNumIncomingValues(); i++) {
    BasicBlock *predBB = Phi.getIncomingBlock(i);
    Value *incomingValue = Phi.getIncomingValue(i);

    // Find the source allocation for this incoming value
    AllocationObject *sourceAlloc = nullptr;
    if (Result.hasAlias(incomingValue)) {
      AllocID aliasId = Result.getAllocId(incomingValue);
      for (AllocationObject *alloc : allocs) {
        if (alloc->getId() == aliasId) {
          sourceAlloc = alloc;
          break;
        }
      }
    }

    if (!sourceAlloc) return false;

    if (!BlockOutStates.contains(predBB)) return false;

    ProgramPointState *predState = BlockOutStates.at(predBB).get();
    if (!predState->hasAllocState(sourceAlloc->getId())) return false;

    const AllocationState *allocState = predState->getAllocState(sourceAlloc->getId());

    // Check 3: All allocations must have the same LockCount
    int32_t lockCount = predState->getLockCount(sourceAlloc->getId());
    if (!firstLockCountSet) {
      firstLockCount = lockCount;
      firstLockCountSet = true;
    } else if (lockCount != firstLockCount) {
      return false;
    }

    DenseSet<uint32_t> &fieldSet = allocFieldSets[sourceAlloc];

    // Collect field information for this allocation
    for (const auto &[offset, fieldInfo] : allocState->getAllFields()) {
      fieldSet.insert(offset);

      // Check 4: Field type information must be consistent across all allocations
      if (!fieldTypeInfo.contains(offset)) {
        fieldTypeInfo[offset] = {fieldInfo.FieldType, fieldInfo.IsOop};
      } else {
        auto [existingType, existingIsOop] = fieldTypeInfo[offset];
        if (existingType != fieldInfo.FieldType || existingIsOop != fieldInfo.IsOop) {
          return false;
        }
      }
    }
  }

  // Check 5: All allocations must have the same set of field offsets
  if (!allocFieldSets.empty()) {
    DenseSet<uint32_t> referenceSet = allocFieldSets.begin()->second;

    for (const auto &[alloc, fieldSet] : allocFieldSets) {
      if (fieldSet != referenceSet) {
        return false;
      }
    }
  }

  return true;
}

static uint32_t computeGEPOffset(GetElementPtrInst *GEP) {
  if (GEP->getNumOperands() != 2)
    return 0;

  Type *SourceType = GEP->getSourceElementType();
  uint32_t ElemSize = SourceType->getScalarSizeInBits() / 8;

  if (ElemSize == 0)
    return 0;

  if (auto *C = dyn_cast<ConstantInt>(GEP->getOperand(1)))
    return C->getZExtValue() * ElemSize;

  return 0;
}

// Key instruction may change the AllocationState
static bool isKeyInstruction(Instruction *I) {
  return isa<CallInst>(I) || isa<StoreInst>(I) || isa<ReturnInst>(I) || isa<PHINode>(I);
}

static bool isValueInvalid(Value *V) {
  if (V->getValueID() == llvm::Value::UndefValueVal) {
    report_fatal_error("store an undef value!");
  }
  return V->getValueID() == llvm::Value::ConstantPointerNullVal;
}

AnalysisKey PartialEscapeAnalysis::Key;

//===----------------------------------------------------------------------===//
// PartialEscapeAnalysis::run - Main Entry for Partial Escape Analysis
//===----------------------------------------------------------------------===//

PEAResult PartialEscapeAnalysis::run(Function &F, FunctionAnalysisManager &FAM) {
  PEAResult Result;

  // Create PhantomObj (ID=0) first
  Result.createAllocationObject(nullptr, false);

  DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> BlockOutStates;
  BlockOutStates.reserve(F.size());

  Visitor.setResult(&Result);
  Visitor.setBlockOutStates(&BlockOutStates);

  auto &LI = FAM.getResult<LoopAnalysis>(F);
  SmallVector<BasicBlock *> RPOBlocks = getRPOOrder(F);

  for (BasicBlock *BB : RPOBlocks) {
    if (BlockOutStates.contains(BB)) continue;

    Loop *L = LI.getLoopFor(BB);

    if (L && L->getHeader() == BB) {
      processLoop(L, BlockOutStates, Result, LI, RPOBlocks);
      continue;
    }

    std::unique_ptr<ProgramPointState> State = mergePredecessorStates(BB, BlockOutStates, Result);
    ProgramPointState *BlockEntryState = Result.createBlockState(BB);
    *BlockEntryState = *State;
    processBlock(BB, State.get());
    BlockOutStates[BB] = std::move(State);
  }

  return Result;
}

SmallVector<BasicBlock *> PartialEscapeAnalysis::getRPOOrder(Function &F) {
  SmallVector<BasicBlock *> Order;
  Order.reserve(F.size());
  ReversePostOrderTraversal<const Function *> RPOT(&F);
  for (const BasicBlock *BB : RPOT)
    Order.push_back(const_cast<BasicBlock *>(BB));
  return Order;
}

std::unique_ptr<ProgramPointState> PartialEscapeAnalysis::mergePredecessorStates(
    BasicBlock *BB,
    DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> &BlockOutStates,
    jeandle::PEAResult &Result) {
  auto Merged = std::make_unique<ProgramPointState>();

  SmallVector<ProgramPointState *> PredStates;
  SmallVector<BasicBlock *> PredBBs;
  for (BasicBlock *Pred : predecessors(BB)) {
    if (BlockOutStates.contains(Pred)) {
      PredStates.push_back(BlockOutStates[Pred].get());
      PredBBs.push_back(Pred);
    }
  }

  if (PredStates.empty()) return Merged;

  Merged->mergeFrom(PredStates, PredBBs, Result, BB);

  return Merged;
}

void PartialEscapeAnalysis::processInstruction(Instruction *I,
                                               ProgramPointState *State) {
  Visitor.setState(State);
  Visitor.visit(I);
}

void PartialEscapeAnalysis::processBlock(BasicBlock *BB,
                                         ProgramPointState *State) {
  for (Instruction &I : *BB) {
    processInstruction(&I, State);

    if (isKeyInstruction(&I)) {
      ProgramPointState *Snap = Visitor.getResult()->createInstState(&I);
      *Snap = *State;
    }
  }
}

void PartialEscapeAnalysis::processLoop(Loop *L,
                                        DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> &BlockOutStates,
                                        PEAResult &Result,
                                        LoopInfo &LI,
                                        const SmallVector<BasicBlock *> &FullRPO) {
  BasicBlock *Header = L->getHeader();
  SmallVector<BasicBlock *> LoopBlocks = getLoopBlocksInRPO(L, LI, FullRPO);

  std::unique_ptr<ProgramPointState> EntryState = mergePredecessorStates(Header, BlockOutStates, Result);

  while (true) {
    for (BasicBlock *BB : LoopBlocks) {
      Loop *InnerL = LI.getLoopFor(BB);

      if (InnerL && InnerL->getHeader() == BB && InnerL != L) {
        processLoop(InnerL, BlockOutStates, Result, LI, FullRPO);
        continue;
      }

      std::unique_ptr<ProgramPointState> State =
          (BB == Header) ? EntryState->copy() : mergePredecessorStates(BB, BlockOutStates, Result);

      ProgramPointState *BlockEntryState = Result.createBlockState(BB);
      *BlockEntryState = *State;
      processBlock(BB, State.get());
      BlockOutStates[BB] = std::move(State);
    }

    std::unique_ptr<ProgramPointState> NewEntryState = mergePredecessorStates(Header, BlockOutStates, Result);

    if (*EntryState == *NewEntryState) {
      LLVM_DEBUG(dbgs() << "PEA: Loop converged\n");
      break;
    }

    EntryState = std::move(NewEntryState);
  }
}

SmallVector<BasicBlock *> PartialEscapeAnalysis::getLoopBlocksInRPO(Loop *L, LoopInfo &LI, const SmallVector<BasicBlock *> &FullRPO) {
  SmallVector<BasicBlock *> LoopBlocks;

  for (BasicBlock *BB : L->blocks()) {
    Loop *InnerL = LI.getLoopFor(BB);
    if (InnerL == L) {
      LoopBlocks.push_back(BB);
    } else if (InnerL->getHeader() == BB && InnerL->getParentLoop() == L) {
      LoopBlocks.push_back(BB);
    }
  }

  SmallVector<BasicBlock *> SortedBlocks;
  for (BasicBlock *BB : FullRPO) {
    if (llvm::is_contained(LoopBlocks, BB)) {
      SortedBlocks.push_back(BB);
    }
  }

  return SortedBlocks;
}

//===----------------------------------------------------------------------===//
// PEAVisitor Implementation - InstVisitor for Partial Escape Analysis
//===----------------------------------------------------------------------===//

void PEAVisitor::visitCallBase(CallBase &I) {
  Function *Callee = I.getCalledFunction();
  if (!Callee) {
    for (Value *Arg : I.args()) {
      if (isJavaHeapPointerType(Arg->getType())) {
        if (Result->hasAlias(Arg)) {
          AllocID AllocId = Result->getAllocId(Arg);
          State->setEscapeState(AllocId, EscapeState::GlobalEscape);
        }
      }
    }
    // Create Phantom Alias for indirect calls returning pointers
    if (isJavaHeapPointerType(I.getType())) {
      Result->createPhantomAlias(&I);
    }
    return;
  }

  StringRef Name = Callee->getName();

  if (Name == "jeandle.new_instance") {
    AllocationObject *Alloc = Result->createAllocationObject(&I, false);
    State->setEscapeState(Alloc->getId(), EscapeState::NoEscape);
    Result->createAlias(&I, Alloc->getId(), 0);
    LLVM_DEBUG(dbgs() << "PEA: Allocation #" << Alloc->getId() << " at " << I << "\n");
    return;
  }

  if (Name == "jeandle.newarray") {
    Value *LengthArg = I.getArgOperand(1);
    uint32_t Length = 0;
    if (auto *C = dyn_cast<ConstantInt>(LengthArg))
      Length = C->getZExtValue();

    if (Length == 0 || Length > PEAConfig::getMaxArrayLength()) {
      LLVM_DEBUG(dbgs() << "PEA: Skipping array allocation, length=" << Length << "\n");
      Result->createPhantomAlias(&I);
      return;
    }

    AllocationObject *Alloc = Result->createAllocationObject(&I, true);
    if (auto *ArrayAlloc = dyn_cast<ArrayAllocationObject>(Alloc))
      ArrayAlloc->setLength(Length);

    State->setEscapeState(Alloc->getId(), EscapeState::NoEscape);
    Result->createAlias(&I, Alloc->getId(), 0);
    LLVM_DEBUG(dbgs() << "PEA: Array allocation #" << Alloc->getId() << " at " << I << "\n");
    return;
  }

  if (Name.starts_with("jeandle.monitorenter_with")) {
    Value *LockObj = I.getArgOperand(0);
    if (Result->hasAlias(LockObj)) {
      AllocID AllocId = Result->getAllocId(LockObj);
      State->incLockCount(AllocId);
      LLVM_DEBUG(dbgs() << "PEA: MonitorEnter on #" << AllocId << "\n");
    }
    // MonitorEnter returns void, no Alias needed
    return;
  }

  if (Name.starts_with("jeandle.monitorexit_with")) {
    Value *LockObj = I.getArgOperand(0);
    if (Result->hasAlias(LockObj)) {
      AllocID AllocId = Result->getAllocId(LockObj);
      State->decLockCount(AllocId);
      LLVM_DEBUG(dbgs() << "PEA: MonitorExit on #" << AllocId << "\n");
    }
    // MonitorExit returns void, no Alias needed
    return;
  }

  // Unknown function call
  for (Value *Arg : I.args()) {
    if (isJavaHeapPointerType(Arg->getType())) {
      if (Result->hasAlias(Arg)) {
        AllocID AllocId = Result->getAllocId(Arg);
        State->setEscapeState(AllocId, EscapeState::GlobalEscape);
      }
    }
  }

  // Create Phantom Alias for unknown calls returning pointers
  if (isJavaHeapPointerType(I.getType())) {
    Result->createPhantomAlias(&I);
  }
}

void PEAVisitor::visitGetElementPtrInst(GetElementPtrInst &I) {
  if (!isJavaHeapPointerType(I.getType())) return;

  Value *Base = I.getPointerOperand();
  uint32_t Offset = computeGEPOffset(&I);

  if (Result->hasAlias(Base)) {
    AliasInfo BasePtr = Result->getAliasInfo(Base);
    AliasInfo FieldPtr = BasePtr.addOffset(Offset);
    Result->createAlias(&I, FieldPtr);
  } else {
    Result->createPhantomAlias(&I);
  }
}

void PEAVisitor::visitStoreInst(StoreInst &I) {
  Value *StoredVal = I.getValueOperand();
  if (isValueInvalid(StoredVal)) return;

  Type *StoredType = StoredVal->getType();
  bool IsOop = containsJavaHeapPtrType(StoredType);

  Value *StoreAddr = I.getPointerOperand();
  AliasInfo StorePtr = Result->getAliasInfo(StoreAddr);

  if (StorePtr.isPhantom() || !StorePtr.hasOffset()) {
    // Unknown object or unknown offset -> conservatively escape
    if (IsOop && Result->hasAlias(StoredVal)) {
      AllocID AllocId = Result->getAllocId(StoredVal);
      State->setEscapeState(AllocId, EscapeState::GlobalEscape);
    }
    return;
  }

  AllocID AllocId = StorePtr.getAllocId();
  uint32_t Offset = StorePtr.getOffset();

  if (State->getEscapeState(AllocId) == EscapeState::GlobalEscape) {
    // Target object escaped -> propagate escape to stored value (indirect escape)
    if (IsOop && Result->hasAlias(StoredVal)) {
      AllocID StoredAllocId = Result->getAllocId(StoredVal);
      if (State->hasAllocState(StoredAllocId)) {
        State->setEscapeState(StoredAllocId, EscapeState::GlobalEscape);
      }
    }
    return;
  }

  State->setField(AllocId, Offset, StoredVal, StoredType, IsOop);
}

void PEAVisitor::visitLoadInst(LoadInst &I) {
  if (!containsJavaHeapPtrType(I.getType())) return;

  Value *LoadAddr = I.getPointerOperand();
  AliasInfo LoadPtr = Result->getAliasInfo(LoadAddr);

  if (LoadPtr.isPhantom() || !LoadPtr.hasOffset()) {
    Result->createPhantomAlias(&I);
    return;
  }

  AllocID AllocId = LoadPtr.getAllocId();
  uint32_t Offset = LoadPtr.getOffset();

  const AllocationState *AS = State->getAllocState(AllocId);
  if (!AS || !AS->hasField(Offset)) {
    Result->createPhantomAlias(&I);
    return;
  }

  const FieldInfo *FI = AS->getField(Offset);
  Value *StoredVal = FI->StoredValue;

  if (StoredVal && Result->hasAlias(StoredVal)) {
    Result->createAlias(&I, Result->getAliasInfo(StoredVal));
  } else {
    Result->createPhantomAlias(&I);
  }
}

void PEAVisitor::visitReturnInst(ReturnInst &I) {
  Value *RetVal = I.getReturnValue();
  if (RetVal) {
    if (Result->hasAlias(RetVal)) {
      AllocID AllocId = Result->getAllocId(RetVal);
      State->setEscapeState(AllocId, EscapeState::GlobalEscape);
      LLVM_DEBUG(dbgs() << "PEA: Escape via return\n");
    }
  }
}

void PEAVisitor::visitPHINode(PHINode &I) {
  // TODO(PEA-MergeIteration): Current implementation lacks proper iterative convergence
  // for non-loop PHI nodes. The issue arises when PHI processing modifies predecessor
  // BlockOutStates after some successor blocks have already been processed.
  //
  // Problem scenario:
  //   bb1 -> bb2 (processed, sees obj1: NoEscape)
  //   bb1 -> bb3 (processing PHI)
  //   bb3: phi(obj1, obj2) -> incompatible -> BlockOutStates[bb1] = GlobalEscape
  //   Result: bb2 sees NoEscape but should see GlobalEscape (incorrect)
  //
  // Current design choices:
  //   1. Loop headers: processLoop provides iterative convergence (correct)
  //   2. Non-loop PHI: markPredAllocationsEscaped modifies predecessors
  //      - Later successors in RPO will see updated states (natural propagation)
  //      - Earlier successors already processed (inaccurate but acceptable for now)
  //
  // Future improvement (Graal-style MergeProcessor):
  //   - Move PHI processing into mergePredecessorStates
  //   - Implement do-while loop inside merge:
  //     bool materialized;
  //     do {
  //       materialized = false;
  //       mergedState->mergeFrom(predecessors);
  //       for (PHINode &Phi : mergeBlock.phis()) {
  //         materialized |= handlePhiInMerge(Phi, mergedState);
  //         if (materialized) {
  //           mergedState->reset();
  //           break; // restart merge
  //         }
  //       }
  //     } while (materialized);
  //   - This ensures all successors see consistent escape states
  //
  // Reference: Graal's PartialEscapeClosure.MergeProcessor.merge() (L932-1052)
  //            Iterates until no more materializations happen during merging

  if (!containsJavaHeapPtrType(I.getType())) return;

  // Helper: mark incoming allocations as escaped in predecessor BlockOutStates
  auto markPredAllocationsEscaped = [&]() {
    for (unsigned i = 0; i < I.getNumIncomingValues(); i++) {
      BasicBlock *PredBB = I.getIncomingBlock(i);
      Value *IncomingVal = I.getIncomingValue(i);

      if (!BlockOutStates->contains(PredBB)) continue;

      AliasInfo IncomingAI = Result->getAliasInfo(IncomingVal);
      if (IncomingAI.isPhantom()) continue;

      AllocID IncomingAllocId = IncomingAI.getAllocId();
      ProgramPointState *PredState = BlockOutStates->at(PredBB).get();

      if (PredState->hasAllocState(IncomingAllocId)) {
        PredState->setEscapeState(IncomingAllocId, EscapeState::GlobalEscape);
      }
    }
  };

  // Collect all incoming AliasInfo
  SmallVector<AliasInfo> incomingAliasInfos;
  SmallVector<AllocID> incomingAllocIds;
  bool hasPhantom = false;

  for (Value *In : I.incoming_values()) {
    AliasInfo AI = Result->getAliasInfo(In);
    incomingAliasInfos.push_back(AI);

    if (AI.isPhantom()) {
      hasPhantom = true;
    } else if (!llvm::is_contained(incomingAllocIds, AI.getAllocId())) {
      incomingAllocIds.push_back(AI.getAllocId());
    }
  }

  // Conservative case (hasPhantom or empty)
  if (incomingAllocIds.empty() || hasPhantom) {
    Result->createPhantomAlias(&I);
    for (AllocID AllocId : incomingAllocIds) {
      if (State->hasAllocState(AllocId)) {
        State->setEscapeState(AllocId, EscapeState::GlobalEscape);
      }
    }
    markPredAllocationsEscaped();
    return;
  }

  // Same AllocationObject
  if (incomingAllocIds.size() == 1) {
    AliasInfo Merged = AliasInfo::merge(incomingAliasInfos);
    Result->createAlias(&I, Merged);
    return;
  }

  // Different AllocationObject
  if (hasEscapedAllocation(incomingAllocIds, State)) {
    Result->createPhantomAlias(&I);
    for (AllocID AllocId : incomingAllocIds) {
      if (State->hasAllocState(AllocId)) {
        State->setEscapeState(AllocId, EscapeState::GlobalEscape);
      }
    }
    markPredAllocationsEscaped();
    return;
  }

  // Compatibility check
  if (checkAllocationCompatibility(incomingAllocIds, State, *BlockOutStates, I, *Result)) {
    AllocationObject *VirtualAlloc = Result->createVirtualAllocationObject(&I);
    Result->createAlias(&I, VirtualAlloc->getId(), 0);

    // Initialize VirtualAlloc's fields by merging incoming objects' fields
    SmallVector<const AllocationState*> PredStates;
    SmallVector<BasicBlock*> PredBBs;

    for (unsigned i = 0; i < I.getNumIncomingValues(); i++) {
      BasicBlock *PredBB = I.getIncomingBlock(i);
      Value *IncomingVal = I.getIncomingValue(i);

      AliasInfo IncomingAI = Result->getAliasInfo(IncomingVal);
      AllocID IncomingAllocId = IncomingAI.getAllocId();

      ProgramPointState *PredState = BlockOutStates->at(PredBB).get();
      PredStates.push_back(PredState->getAllocState(IncomingAllocId));
      PredBBs.push_back(PredBB);
    }

    // Create AllocationState for VirtualAlloc and merge fields
    AllocationState &VirtualState = State->AllocationStates[VirtualAlloc->getId()];
    VirtualState.mergeFrom(PredStates, PredBBs, VirtualAlloc->getId(), *Result, I.getParent());
  } else {
    Result->createPhantomAlias(&I);
    for (AllocID AllocId : incomingAllocIds) {
      if (State->hasAllocState(AllocId)) {
        State->setEscapeState(AllocId, EscapeState::GlobalEscape);
      }
    }
    markPredAllocationsEscaped();
  }
}

void PEAVisitor::visitSelectInst(SelectInst &I) {
  if (!containsJavaHeapPtrType(I.getType())) return;

  Value *TrueVal = I.getTrueValue();
  Value *FalseVal = I.getFalseValue();

  AliasInfo TruePtr = Result->hasAlias(TrueVal) ? Result->getAliasInfo(TrueVal) : AliasInfo();
  AliasInfo FalsePtr = Result->hasAlias(FalseVal) ? Result->getAliasInfo(FalseVal) : AliasInfo();

  // Mark escaped if different allocations
  if (TruePtr.getAllocId() != FalsePtr.getAllocId()) {
    if (!TruePtr.isPhantom()) State->setEscapeState(TruePtr.getAllocId(), EscapeState::GlobalEscape);
    if (!FalsePtr.isPhantom()) State->setEscapeState(FalsePtr.getAllocId(), EscapeState::GlobalEscape);
  }

  AliasInfo Merged = AliasInfo::merge(TruePtr, FalsePtr);
  Result->createAlias(&I, Merged);
}
