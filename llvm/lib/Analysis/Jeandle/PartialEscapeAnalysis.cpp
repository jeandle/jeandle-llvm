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
#include "llvm/IR/Jeandle/Metadata.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

#define DEBUG_TYPE "partial-escape-analysis"

using namespace llvm;
using namespace jeandle;

bool PEAConfig::Enabled = true;
uint32_t PEAConfig::MaxArrayLength = 32;

//===----------------------------------------------------------------------===//
// PointsToGraph Implementation
//===----------------------------------------------------------------------===//

AllocationNode *PointsToGraph::createAllocation(CallBase *Call, bool IsArray) {
  AllocationNode *Node;

  if (IsArray) {
    assert(Call && "IsArray=true must have Call");
    assert(Call->getCalledFunction() && (Call->getCalledFunction()->getName() == "jeandle.newarray"));

    // jeandle.newarray: args = [array_klass, length]
    Value *LengthArg = Call->getArgOperand(1);
    uint32_t Length = 0;
    if (auto *C = dyn_cast<ConstantInt>(LengthArg))
      Length = C->getZExtValue();

    if (Length == 0) {
      LLVM_DEBUG(dbgs() << "PEA: Skipping array allocation, length=0 means dynamic length\n");
      return nullptr;
    }

    if (Length > PEAConfig::getMaxArrayLength()) {
      LLVM_DEBUG(dbgs() << "PEA: Skipping array allocation, length=" << Length
                        << " (max=" << PEAConfig::getMaxArrayLength() << ")\n");
      return nullptr;
    }

    auto *ArrayNode = new ArrayAllocationNode(Call, NextAllocId++);
    ArrayNode->setLength(Length);
    Node = ArrayNode;
  } else {
    Node = new AllocationNode(Call, NextAllocId++);
  }

  if (Call)
    ValueToNode[Call] = Node;

  Allocations.push_back(std::unique_ptr<AllocationNode>(Node));
  return Node;
}

PointerNode *PointsToGraph::createPointer(Value *V, PEANode *Target) {
  assert(V);
  assert(Target && "PointerNode must have a target");

  auto *Node = new PointerNode(V, NextPtrId++);
  addEdge(Node, Target);
  ValueToNode[V] = Node;

  Pointers.push_back(std::unique_ptr<PointerNode>(Node));
  return Node;
}

FieldNode *PointsToGraph::createField(GetElementPtrInst *GEP, PEANode *Base, uint32_t Offset) {
  assert(GEP);

  auto *Node = new FieldNode(GEP, NextFieldId++);
  addBase(Base, Node);
  Node->setOffset(Offset);
  ValueToNode[GEP] = Node;

  Fields.push_back(std::unique_ptr<FieldNode>(Node));
  return Node;
}

AllocationNode *PointsToGraph::getAllocation(uint32_t Id) const {
  if (Id < Allocations.size())
    return Allocations[Id].get();
  return nullptr;
}

AllocationNode *PointsToGraph::getAllocationForValue(Value *V) const {
  PEANode *N = ValueToNode.lookup(V);
  if (N && N->isAllocation())
    return N->asAllocation();
  return nullptr;
}

PointerNode *PointsToGraph::getPointerForValue(Value *V) const {
  PEANode *N = ValueToNode.lookup(V);
  if (N && N->isPointer())
    return N->asPointer();
  return nullptr;
}

FieldNode *PointsToGraph::getFieldForValue(Value *V) const {
  PEANode *N = ValueToNode.lookup(V);
  if (N && N->isField())
    return N->asField();
  return nullptr;
}

PEANode *PointsToGraph::getNodeForValue(Value *V) const {
  return ValueToNode.lookup(V);
}

void PointsToGraph::propagateReferences() {
  for (const auto &Ptr : Pointers) {
    pointsTo(Ptr.get());
  }

  for (const auto &Field : Fields) {
    pointsTo(Field.get());
  }
}

void PointsToGraph::addBase(PEANode *From, FieldNode *To) {
  if (!From || !To) return;

  if (From->isAllocation()) {
    addEdge(From, To);
  } else if (From->isPointer()) {
    if (To->hasBase(From)) return;
    To->addBase(From);
    From->addBaseUse(To);
  }
}

void PointsToGraph::addEdge(PEANode *From, PEANode *To) {
  if (!From || !To || From->hasEdge(To))
    return;
  From->addEdge(To);
  To->addUse(From);
}

void PointsToGraph::removeEdge(PEANode *From, PEANode *To) {
  if (!From || !To) return;

  auto EdgeIt = llvm::find(From->Edges, To);
  if (EdgeIt != From->Edges.end())
    From->Edges.erase(EdgeIt);

  auto UseIt = llvm::find(To->Uses, From);
  if (UseIt != To->Uses.end())
    To->Uses.erase(UseIt);
}

SmallVector<AllocationNode *> PointsToGraph::pointsTo(PEANode *Node) {
  if (!Node) return {};

  if (Node->isAllocation()) {
    return {Node->asAllocation()};
  }

  bool HasDeferred = false;
  for (PEANode *Edge : Node->getEdges()) {
    if (!Edge->isAllocation()) {
      HasDeferred = true;
      break;
    }
  }

  if (!HasDeferred) {
    SmallVector<AllocationNode *> Allocs;
    for (PEANode *Edge : Node->getEdges()) {
      Allocs.push_back(Edge->asAllocation());
    }
    return Allocs;
  }

  SmallVector<AllocationNode *> Allocs;
  SmallVector<PEANode *> DeferredEdges;

  for (PEANode *Edge : Node->getEdges()) {
    if (Edge->isAllocation()) {
      Allocs.push_back(Edge->asAllocation());
    } else {
      DeferredEdges.push_back(Edge);
      for (AllocationNode *Alloc : pointsTo(Edge)) {
        if (!llvm::is_contained(Allocs, Alloc))
          Allocs.push_back(Alloc);
      }
    }
  }

  for (AllocationNode *Alloc : Allocs) {
    if (!Node->hasEdge(Alloc))
      addEdge(Node, Alloc);
  }

  for (PEANode *Deferred : DeferredEdges) {
    removeEdge(Node, Deferred);
  }

  return Allocs;
}

//===----------------------------------------------------------------------===//
// PEAResult Implementation
//===----------------------------------------------------------------------===//

ProgramPointState *PEAResult::createState(Instruction *Inst) {
  auto It = States.find(Inst);
  if (It != States.end())
    return It->second.get();

  auto S = std::make_unique<ProgramPointState>(Inst);
  ProgramPointState *Ptr = S.get();
  States[Inst] = std::move(S);
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

ProgramPointState *PEAResult::getState(Instruction *Inst) const {
  auto It = States.find(Inst);
  return It != States.end() ? It->second.get() : nullptr;
}

ProgramPointState *PEAResult::getBlockState(BasicBlock *BB) const {
  auto It = BlockStates.find(BB);
  return It != BlockStates.end() ? It->second.get() : nullptr;
}

EscapeState PEAResult::getEscapeStateAt(Instruction *I, uint32_t AllocId) const {
  if (hasState(I)) {
    return getState(I)->getEscapeState(AllocId);
  }

  BasicBlock *BB = I->getParent();
  for (Instruction &Prev : reverse(*BB)) {
    if (&Prev == I) break;
    if (hasState(&Prev)) {
      return getState(&Prev)->getEscapeState(AllocId);
    }
  }

  if (hasBlockState(BB)) {
    return getBlockState(BB)->getEscapeState(AllocId);
  }

  return EscapeState::Unknown;
}

EscapeState PEAResult::getEscapeStateAt(Instruction *I, AllocationNode *Alloc) const {
  return Alloc ? getEscapeStateAt(I, Alloc->getId()) : EscapeState::Unknown;
}

int32_t PEAResult::getLockCountAt(Instruction *I, uint32_t AllocId) const {
  ProgramPointState *S = getState(I);
  return S ? S->getLockCount(AllocId) : 0;
}

SmallVector<Instruction *> PEAResult::getMaterializePoints(uint32_t AllocId) const {
  SmallVector<Instruction *> Points;
  for (const auto &[Inst, S] : States) {
    if (S->getEscapeState(AllocId) == EscapeState::GlobalEscape)
      Points.push_back(Inst);
  }
  return Points;
}

SmallVector<Instruction *> PEAResult::getAllMaterializePoints() const {
  SmallVector<Instruction *> Points;
  for (const auto &Alloc : Graph.allocations()) {
    auto AllocPoints = getMaterializePoints(Alloc->getId());
    for (Instruction *I : AllocPoints) {
      if (!llvm::is_contained(Points, I))
        Points.push_back(I);
    }
  }
  return Points;
}

SmallVector<AllocationNode *> PEAResult::getTrackedAllocations() const {
  SmallVector<AllocationNode *> Result;
  for (const auto &Alloc : Graph.allocations()) {
    if (!Graph.isPhantom(Alloc.get()))
      Result.push_back(Alloc.get());
  }
  return Result;
}

Value *PEAResult::getFieldValueAt(Instruction *I, uint32_t AllocId, uint32_t Offset) const {
  const AllocationState *AS = getAllocationStateAt(I, AllocId);
  if (!AS) return nullptr;
  const FieldInfo *FI = AS->getField(Offset);
  return FI ? FI->StoredValue : nullptr;
}

const AllocationState *PEAResult::getAllocationStateAt(Instruction *I, uint32_t AllocId) const {
  ProgramPointState *S = getState(I);
  if (!S) return nullptr;
  return S->getAllocState(AllocId);
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

//===----------------------------------------------------------------------===//
// VirtualPhiMap Implementation
//===----------------------------------------------------------------------===//

void VirtualPhiMap::addPendingPhi(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset, BasicBlock *PredBB, Value *Val) {
  auto FieldKey = std::make_pair(AllocId, Offset);
  PendingPHIs[MergeBB][FieldKey][PredBB] = Val;
}

bool VirtualPhiMap::hasPendingPhi(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset) const {
  auto MergeIt = PendingPHIs.find(MergeBB);
  if (MergeIt == PendingPHIs.end()) return false;
  return MergeIt->second.contains(std::make_pair(AllocId, Offset));
}

Value *VirtualPhiMap::getPendingValue(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset, BasicBlock *PredBB) const {
  auto MergeIt = PendingPHIs.find(MergeBB);
  if (MergeIt == PendingPHIs.end()) return nullptr;
  auto FieldIt = MergeIt->second.find(std::make_pair(AllocId, Offset));
  if (FieldIt == MergeIt->second.end()) return nullptr;
  auto ValIt = FieldIt->second.find(PredBB);
  return ValIt != FieldIt->second.end() ? ValIt->second : nullptr;
}

const DenseMap<BasicBlock *, Value *> *
VirtualPhiMap::getPendingInputs(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset) const {
  auto MergeIt = PendingPHIs.find(MergeBB);
  if (MergeIt == PendingPHIs.end()) return nullptr;
  auto FieldIt = MergeIt->second.find(std::make_pair(AllocId, Offset));
  return FieldIt != MergeIt->second.end() ? &FieldIt->second : nullptr;
}

//===----------------------------------------------------------------------===//
// AllocationState Implementation
//===----------------------------------------------------------------------===//

void AllocationState::mergeFrom(const AllocationState &Other, uint32_t AllocId,
                                VirtualPhiMap &PhiMap, BasicBlock *MergeBB,
                                BasicBlock *PredBB) {
  assert(ES != EscapeState::Unknown && Other.ES != EscapeState::Unknown);
  ES = std::max(ES, Other.ES);

  if (LockCount != Other.LockCount)
    LockCount = LOCK_COUNT_UNKNOWN;

  SmallVector<uint32_t> AllOffsets;
  for (const auto &[Offset, FI] : Fields)
    AllOffsets.push_back(Offset);
  for (const auto &[Offset, FI] : Other.Fields)
    if (!llvm::is_contained(AllOffsets, Offset))
      AllOffsets.push_back(Offset);

  for (uint32_t Offset : AllOffsets) {
    bool HasThis = hasField(Offset);
    bool HasOther = Other.hasField(Offset);

    if (HasThis && HasOther) {
      const FieldInfo *MyFI = getField(Offset);
      const FieldInfo *OtherFI = Other.getField(Offset);
      if (MyFI->StoredValue != OtherFI->StoredValue) {
        PhiMap.addPendingPhi(MergeBB, AllocId, Offset, PredBB, OtherFI->StoredValue);
      }
    } else if (HasThis && !HasOther) {
      PhiMap.addPendingPhi(MergeBB, AllocId, Offset, PredBB, nullptr);
    } else if (!HasThis && HasOther) {
      const FieldInfo *OtherFI = Other.getField(Offset);
      Fields[Offset] = FieldInfo(nullptr, OtherFI->FieldType, OtherFI->IsOop);
      PhiMap.addPendingPhi(MergeBB, AllocId, Offset, PredBB, OtherFI->StoredValue);
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

void ProgramPointState::mergeFrom(const ProgramPointState *Other, VirtualPhiMap &PhiMap,
                                  BasicBlock *MergeBB, BasicBlock *PredBB) {
  if (!Other) return;

  for (const auto &[AllocId, OtherAS] : Other->AllocationStates) {
    if (hasAllocState(AllocId)) {
      AllocationStates[AllocId].mergeFrom(OtherAS, AllocId, PhiMap, MergeBB, PredBB);
    } else {
      AllocationStates[AllocId] = AllocationState();
      AllocationStates[AllocId].ES = OtherAS.ES;
      AllocationStates[AllocId].LockCount = OtherAS.LockCount;
      for (const auto &[Offset, FI] : OtherAS.getAllFields()) {
        AllocationStates[AllocId].setField(Offset, nullptr, FI.FieldType, FI.IsOop);
        PhiMap.addPendingPhi(MergeBB, AllocId, Offset, PredBB, FI.StoredValue);
      }
    }
  }

  for (const auto &[AllocId, MyAS] : AllocationStates) {
    if (!Other->hasAllocState(AllocId)) {
      for (const auto &[Offset, FI] : MyAS.getAllFields()) {
        PhiMap.addPendingPhi(MergeBB, AllocId, Offset, PredBB, nullptr);
      }
    }
  }
}

ProgramPointState &ProgramPointState::operator=(const ProgramPointState &Other) {
  if (this == &Other) return *this;

  Inst = Other.Inst;
  AllocationStates = Other.AllocationStates;
  return *this;
}

std::unique_ptr<ProgramPointState> ProgramPointState::copy() const {
  return std::make_unique<ProgramPointState>(*this);
}

bool ProgramPointState::operator==(const ProgramPointState &Other) const {
  if (Inst != Other.Inst) return false;

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

static SmallVector<AllocationNode *> getHolderAllocations(FieldNode *Field, PointsToGraph &Graph) {
  SmallVector<AllocationNode *> HolderAllocs;

  for (PEANode *Use : Field->getUses()) {
    assert(Use->isAllocation());
    HolderAllocs.push_back(Use->asAllocation());
  }

  for (PEANode *Base : Field->getBases()) {
    assert(Base->isPointer());
    for (AllocationNode *Alloc : Graph.pointsTo(Base))
      HolderAllocs.push_back(Alloc);
  }

  return HolderAllocs;
}

static uint32_t computeGEPOffset(GetElementPtrInst *GEP) {
  if (GEP->getSourceElementType()->isIntegerTy(8) && GEP->getNumOperands() == 2) {
    if (auto *C = dyn_cast<ConstantInt>(GEP->getOperand(1)))
      return C->getZExtValue();
  }
  return 0;
}

// Key instruction may change the AllocationState
static bool isKeyInstruction(Instruction *I) {
  return isa<CallInst>(I) || isa<StoreInst>(I) || isa<ReturnInst>(I);
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
  Visitor.setResult(&Result);

  AllocationNode *Phantom = Result.Graph.createAllocation(nullptr, false);
  Result.Graph.setPhantomObj(Phantom);

  DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> BlockOutStates;

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
    processBlock(BB, State.get(), Result);
    BlockOutStates[BB] = std::move(State);
  }

  Result.Graph.propagateReferences();

  return Result;
}

SmallVector<BasicBlock *> PartialEscapeAnalysis::getRPOOrder(Function &F) {
  SmallVector<BasicBlock *> Order;
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

  *Merged = *(PredStates[0]);

  for (size_t i = 1; i < PredStates.size(); i++) {
    Merged->mergeFrom(PredStates[i], Result.PhiMap, BB, PredBBs[i]);
  }

  return Merged;
}

void PartialEscapeAnalysis::processInstruction(Instruction *I,
                                               ProgramPointState *State,
                                               PEAResult &Result) {
  State->setInstruction(I);
  Visitor.setState(State);
  Visitor.visit(I);
}

void PartialEscapeAnalysis::processBlock(BasicBlock *BB,
                                         ProgramPointState *State,
                                         PEAResult &Result) {
  for (Instruction &I : *BB) {
    processInstruction(&I, State, Result);

    if (isKeyInstruction(&I)) {
      ProgramPointState *Snap = Result.createState(&I);
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
      processBlock(BB, State.get(), Result);
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

void PartialEscapeAnalysis::PEAVisitor::visitCallBase(CallBase &I) {
  Function *Callee = I.getCalledFunction();
  if (!Callee) {
    if (Result->Graph.hasNodeForValue(&I)) {
      PEANode *Node = Result->Graph.getNodeForValue(&I);
      for (AllocationNode *Alloc : Result->Graph.pointsTo(Node))
        State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
    }
    for (Value *Arg : I.args()) {
      if (isJavaHeapPointerType(Arg->getType()) && Result->Graph.hasNodeForValue(Arg)) {
        PEANode *ArgNode = Result->Graph.getNodeForValue(Arg);
        for (AllocationNode *Alloc : Result->Graph.pointsTo(ArgNode))
          State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
      }
    }
    return;
  }

  StringRef Name = Callee->getName();

  if (Name == "jeandle.new_instance") {
    AllocationNode *Alloc = Result->Graph.createAllocation(&I, false);
    State->setEscapeState(Alloc->getId(), EscapeState::NoEscape);
    Result->Graph.createPointer(&I, Alloc);
    LLVM_DEBUG(dbgs() << "PEA: Allocation #" << Alloc->getId() << " at " << I << "\n");
    return;
  }

  if (Name == "jeandle.newarray") {
    AllocationNode *Alloc = Result->Graph.createAllocation(&I, true);
    if (!Alloc) {
      LLVM_DEBUG(dbgs() << "PEA: Array allocation not created because of length exceeding limit\n");
      return;
    }
    State->setEscapeState(Alloc->getId(), EscapeState::NoEscape);
    Result->Graph.createPointer(&I, Alloc);
    LLVM_DEBUG(dbgs() << "PEA: Array allocation #" << Alloc->getId() << " at " << I << "\n");
    return;
  }

  if (Name.starts_with("jeandle.monitorenter_with")) {
    Value *LockObj = I.getArgOperand(0);
    if (Result->Graph.hasNodeForValue(LockObj)) {
      PEANode *Node = Result->Graph.getNodeForValue(LockObj);
      for (AllocationNode *Alloc : Result->Graph.pointsTo(Node)) {
        State->incLockCount(Alloc->getId());
        LLVM_DEBUG(dbgs() << "PEA: MonitorEnter on #" << Alloc->getId() << "\n");
      }
    }
    return;
  }

  if (Name.starts_with("jeandle.monitorexit_with")) {
    Value *LockObj = I.getArgOperand(0);
    if (Result->Graph.hasNodeForValue(LockObj)) {
      PEANode *Node = Result->Graph.getNodeForValue(LockObj);
      for (AllocationNode *Alloc : Result->Graph.pointsTo(Node)) {
        State->decLockCount(Alloc->getId());
        LLVM_DEBUG(dbgs() << "PEA: MonitorExit on #" << Alloc->getId() << "\n");
      }
    }
    return;
  }

  // Unknown function call, ArgEscape conservatively
  for (Value *Arg : I.args()) {
    if (isJavaHeapPointerType(Arg->getType()) && Result->Graph.hasNodeForValue(Arg)) {
      PEANode *ArgNode = Result->Graph.getNodeForValue(Arg);
      for (AllocationNode *Alloc : Result->Graph.pointsTo(ArgNode))
        State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
    }
  }
}

void PartialEscapeAnalysis::PEAVisitor::visitGetElementPtrInst(GetElementPtrInst &I) {
  Value *Base = I.getPointerOperand();
  uint32_t Offset = computeGEPOffset(&I);

  PEANode *BaseNode = Result->Graph.hasNodeForValue(Base)
                          ? Result->Graph.getNodeForValue(Base)
                          : Result->Graph.getPhantomObj();

  FieldNode *Field = Result->Graph.getFieldForValue(&I);
  if (!Field) {
    Field = Result->Graph.createField(&I, BaseNode, Offset);
  } else {
    Result->Graph.addBase(BaseNode, Field);
  }
}

void PartialEscapeAnalysis::PEAVisitor::visitStoreInst(StoreInst &I) {
  Value *StoredVal = I.getValueOperand();
  if (isValueInvalid(StoredVal)) return;

  Value *StoreAddr = I.getPointerOperand();
  Type *StoredType = StoredVal->getType();
  bool IsOop = containsJavaHeapPtrType(StoredType);

  // StoreAddr not in graph (PhantomObj or unknown address)
  if (!Result->Graph.hasNodeForValue(StoreAddr)) {
    if (IsOop && Result->Graph.hasNodeForValue(StoredVal)) {
      // Store pointer to unknown address -> escape StoredVal
      PEANode *ValNode = Result->Graph.getNodeForValue(StoredVal);
      for (AllocationNode *Alloc : Result->Graph.pointsTo(ValNode))
        State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
    }
    return;
  }

  // StoreAddr in graph (FieldNode)
  PEANode *AddrNode = Result->Graph.getNodeForValue(StoreAddr);
  assert(AddrNode->isField());
  FieldNode *Field = AddrNode->asField();
  uint32_t Offset = Field->getOffset();

  // Find all allocations that hold this field
  SmallVector<AllocationNode *> HolderAllocs = getHolderAllocations(Field, Result->Graph);

  // Record field value for each holder
  for (AllocationNode *Alloc : HolderAllocs) {
    if (Result->Graph.isPhantom(Alloc)) continue;

    State->setField(Alloc->getId(), Offset, StoredVal, StoredType, IsOop);

    // For pointer types, also create Deferred Edge in graph
    if (IsOop && Result->Graph.hasNodeForValue(StoredVal)) {
      PEANode *ValNode = Result->Graph.getNodeForValue(StoredVal);
      Result->Graph.addEdge(Field, ValNode);
    }
  }
}

void PartialEscapeAnalysis::PEAVisitor::visitLoadInst(LoadInst &I) {
  if (!containsJavaHeapPtrType(I.getType())) return;

  Value *LoadAddr = I.getPointerOperand();

  if (Result->Graph.hasNodeForValue(LoadAddr)) {
    Result->Graph.createPointer(&I, Result->Graph.getNodeForValue(LoadAddr));
  } else {
    Result->Graph.createPointer(&I, Result->Graph.getPhantomObj());
  }
}

void PartialEscapeAnalysis::PEAVisitor::visitReturnInst(ReturnInst &I) {
  Value *RetVal = I.getReturnValue();
  if (RetVal && Result->Graph.hasNodeForValue(RetVal)) {
    PEANode *RetNode = Result->Graph.getNodeForValue(RetVal);
    // Return make RetVal escape
    for (AllocationNode *Alloc : Result->Graph.pointsTo(RetNode))
      State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
    LLVM_DEBUG(dbgs() << "PEA: Escape via return\n");
  }
}

void PartialEscapeAnalysis::PEAVisitor::visitPHINode(PHINode &I) {
  if (!containsJavaHeapPtrType(I.getType())) return;

  SmallVector<PEANode *> Targets;

  for (Value *In : I.incoming_values()) {
    PEANode *InNode = (Result->Graph.hasNodeForValue(In)) ? Result->Graph.getNodeForValue(In) : Result->Graph.getPhantomObj();
    if (!llvm::is_contained(Targets, InNode))
      Targets.push_back(InNode);
  }

  PointerNode *PtrNode = Result->Graph.createPointer(&I, Targets[0]);
  for (size_t i = 1; i < Targets.size(); i++)
    Result->Graph.addEdge(PtrNode, Targets[i]);
}

void PartialEscapeAnalysis::PEAVisitor::visitSelectInst(SelectInst &I) {
  if (!containsJavaHeapPtrType(I.getType())) return;

  Value *TrueVal = I.getTrueValue();
  Value *FalseVal = I.getFalseValue();

  AllocationNode *Phantom = Result->Graph.getPhantomObj();

  PEANode *TrueNode = Result->Graph.hasNodeForValue(TrueVal)
                          ? Result->Graph.getNodeForValue(TrueVal)
                          : Phantom;

  PEANode *FalseNode = Result->Graph.hasNodeForValue(FalseVal)
                           ? Result->Graph.getNodeForValue(FalseVal)
                           : Phantom;

  PointerNode *PtrNode = Result->Graph.createPointer(&I, TrueNode);
  if (TrueNode != FalseNode)
    Result->Graph.addEdge(PtrNode, FalseNode);
}

//===----------------------------------------------------------------------===//
// Is Tracked Address
//===----------------------------------------------------------------------===//

bool PartialEscapeAnalysis::isTrackedAddress(Value *Addr, ProgramPointState *State,
                                              PEAResult &Result) {
  return Result.Graph.hasNodeForValue(Addr);
}

//===----------------------------------------------------------------------===//
// Mark Escaped
//===----------------------------------------------------------------------===//

void PartialEscapeAnalysis::markEscaped(Value *V, ProgramPointState *State,
                                         PEAResult &Result) {
  if (!Result.Graph.hasNodeForValue(V)) return;

  PEANode *Node = Result.Graph.getNodeForValue(V);
  for (AllocationNode *Alloc : Result.Graph.pointsTo(Node))
    State->setEscapeState(Alloc->getId(), EscapeState::GlobalEscape);
}