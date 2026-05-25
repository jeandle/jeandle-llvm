//===- PartialEscapeAnalysis.h - Partial Escape Analysis -----------------===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file implements Partial Escape Analysis (PEA) as a flow-sensitive
// analysis. Unlike traditional escape analysis that produces a single
// "escape/no-escape" answer, PEA tracks escape states at each program point,
// enabling materialization at escape points while optimizing other paths.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_PARTIAL_ESCAPE_ANALYSIS_H
#define LLVM_ANALYSIS_JEANDLE_PARTIAL_ESCAPE_ANALYSIS_H

#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/STLExtras.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/ArrayRef.h"
#include "llvm/Analysis/LoopInfo.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Instruction.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/InstVisitor.h"
#include "llvm/IR/PassManager.h"
#include "llvm/IR/Value.h"
#include <memory>
#include <string>
#include <utility>
#include <variant>

namespace llvm {

class PartialEscapeAnalysis;
class Loop;

} // namespace llvm

namespace llvm::jeandle {

/// \class PEAConfig
/// \brief Configuration for Partial Escape Analysis.
///
/// Configuration sources (priority from high to low):
/// 1. JDK setter calls (via JeandleDoPartialEscapeAnalysis JVM flags)
/// 2. LLVM command line parameters (jeandle-pea, jeandle-pea-max-array-length)
/// 3. Default values (true for enabled, 32 for max array length)
///
/// Usage examples:
/// - JDK: java -XX:-JeandleDoPartialEscapeAnalysis -XX:JeandlePEAMaxArrayLength=16 MyApp
/// - LLVM standalone: opt -jeandle-pea=false -jeandle-pea-max-array-length=64 input.ll
class PEAConfig {
  static bool Enabled;
  static uint32_t MaxArrayLength;
  static uint32_t MaxLoopIteration;

public:
  static void setEnabled(bool Val) { Enabled = Val; }
  static bool isEnabled() { return Enabled; }

  static void setMaxArrayLength(uint32_t Val) { MaxArrayLength = Val; }
  static uint32_t getMaxArrayLength() { return MaxArrayLength; }

  static void setMaxLoopIteration(uint32_t Val) { MaxLoopIteration = Val; }
  static uint32_t getMaxLoopIteration() { return MaxLoopIteration; }
};

enum class EscapeState : uint8_t {
  Unknown,
  NoEscape,
  GlobalEscape
};

/// AllocID - Unique identifier for an allocation object
///
/// ID=0 reprensents a special allocation node named PhantomObj.
///
/// Inspired by HotSpot C2's phantom_object, PhantomObj represents objects whose
/// origin cannot be traced within the current function:
/// - Global variables and static fields
/// - Function parameters from external callers
/// - Objects loaded from untracked addresses
/// - Results of unknown function calls
///
/// PhantomObj is always considered GlobalEscape.
using AllocID = uint32_t;

class AllocationObject;
class ArrayAllocationObject;
class VirtualAllocationObject;
class VirtualPhiNode;
class AllocationState;
class PEAResult;
struct LazyObjectBundle;

/// \class AllocationObject
/// \brief Base class representing an allocation site in the program.
///
/// AllocationObject represents a unique allocation that can be tracked by
/// Partial Escape Analysis. Each allocation has a unique ID that is used
/// to query its AllocationState across different program points.
///
/// Key Properties:
/// ---------------
/// - Id: Unique identifier for state tracking
/// - Source: The IR Value that created this allocation
///   - nullptr for PhantomObj (ID=0)
///   - CallInst for jeandle.new_instance/newarray (regular allocations)
///   - PHINode for VirtualAllocationObject (PHI-merged allocations)
class AllocationObject {
  AllocID Id;
  Value *Source;

  /// TODO(PEA-Deopt): Add Klass for deoptimization materialization
  /// - uintptr_t Klass = 0; (from jeandle.new_instance argument)
  /// - Used to reconstruct virtual object when deoptimization occurs
  /// - lazy_object bundle format: {alloc_id, klass, field_count, field_values...}

  // uintptr_t Klass = 0;  // TODO: implement after type analysis is stable

public:
  AllocationObject(AllocID Id, Value *V) : Id(Id), Source(V) {}
  virtual ~AllocationObject() = default;

  AllocID getId() const { return Id; }
  Value *getSource() const { return Source; }

  virtual bool isArrayAllocation() const { return false; }
  virtual bool isVirtualAllocation() const { return false; }

  /// TODO(PEA-Deopt): Add Klass getter/setter

  // uintptr_t getKlass() const { return Klass; }
  // void setKlass(uintptr_t K) { Klass = K; }
  static bool classof(const AllocationObject *) { return true; }
};

/// \class ArrayAllocationObject
/// \brief Represents an array allocation.
///
/// Only array allocations with a statically known size can be processed by
/// Partial Escape Analysis. In order to limit the overhead introduced by PEA,
/// only arrays up to a configurable maximum size (default 32) are processed.
///
/// Length Categories:
/// ------------------
/// - 0: Dynamic length (unknown at compile time) - not tracked
/// - ≤PAEConfig::MaxArrayLength: Optimizable length - tracked by PEA
/// - >PAEConfig::MaxArrayLength: Large length - not tracked (too much overhead)
class ArrayAllocationObject : public AllocationObject {
  uint32_t Length = 0;

public:
  ArrayAllocationObject(AllocID Id, Value *V)
      : AllocationObject(Id, V) {}

  uint32_t getLength() const { return Length; }
  void setLength(uint32_t L) { Length = L; }

  bool isArrayAllocation() const override { return true; }

  static bool classof(const AllocationObject *AO) {
    return AO->isArrayAllocation();
  }
};

/// \class VirtualAllocationObject
/// \brief Represents a "merged" allocation created when a PHI pointer points
///        to multiple different allocations that are compatible.
///
/// When PHI pointer points to multiple allocations (obj1, obj2, ...)
/// If they are NoEscape and compatible (same size, lock state, etc.)
/// Create a VirtualAllocationObject to represent the merged object
/// Field values become PHI nodes: field_phi = phi [val1, val2, ...]
///
/// Example:
/// ```
/// bb1: obj1 = new A(); obj1.field = 42
/// bb2: obj2 = new A(); obj2.field = 100
/// merge: p = phi [obj1, obj2]
///        val = p.field  // can be replaced by: val_phi = phi [42, 100]
/// ```
/// If not compatible, all merged allocations are marked GlobalEscape.
class VirtualAllocationObject : public AllocationObject {
public:
  VirtualAllocationObject(AllocID Id, PHINode *Phi)
      : AllocationObject(Id, Phi) {}

  PHINode *getSourcePhi() const {
    return cast<PHINode>(getSource());
  }

  bool isVirtualAllocation() const override { return true; }

  static bool classof(const AllocationObject *AO) {
    return AO->isVirtualAllocation();
  }
};

using StoredValueTy = std::variant<Value *, VirtualPhiNode *>;

struct FieldInfo {
  StoredValueTy StoredValue;
  Type *FieldType;
  bool IsOop;

  FieldInfo() : StoredValue(static_cast<Value *>(nullptr)), FieldType(nullptr), IsOop(false) {}
  FieldInfo(Value *V, Type *T, bool O) : StoredValue(V), FieldType(T), IsOop(O) {}
  FieldInfo(VirtualPhiNode *VPhi, Type *T, bool O) : StoredValue(VPhi), FieldType(T), IsOop(O) {}
  FieldInfo(StoredValueTy V, Type *T, bool O) : StoredValue(V), FieldType(T), IsOop(O) {}
};

//===----------------------------------------------------------------------===//
// AllocationState - Complete dynamic state for one allocation
//===----------------------------------------------------------------------===//

/// \class AllocationState
/// \brief Complete dynamic state for one allocation at a program point.
///
/// Tracks all fields (both pointer and primitive types) for:
/// - Scalar replacement (store-load forwarding)
/// - Deoptimization materialization (lazy_object bundle)
///
/// Key Design:
/// -----------
/// - EscapeState: Dynamic escape status (Unknown/NoEscape/GlobalEscape)
/// - LockCount: Synchronized lock count for lock elimination
/// - Fields: All tracked field values (pointer + primitive)
///
/// State Components:
/// -----------------
/// 1. EscapeState - Dynamic escape status at current program point:
///    - Unknown:      Initial state, not yet analyzed
///    - NoEscape:     Allocation is confined, can be scalar-replaced
///    - GlobalEscape: Allocation escapes globally (stored to global field,
///                    returned, passed to unknown function, etc.)
///
/// 2. LockCount - Synchronized lock count for lock elimination:
///    - Tracks nested synchronized blocks on same object
///    - Enables lock elimination when count reaches zero
///    - Merging states with different LockCount marks object as GlobalEscape
///
/// 3. Fields - DenseMap<Offset, FieldInfo> for scalar replacement:
///    - Tracks field values (both pointer and primitive types)
///    - Enables store-load forwarding for scalar replacement
///    - Stores values needed for deoptimization materialization (lazy_object)
class AllocationState {
  EscapeState ES;
  uint32_t LockCount;

  DenseMap<uint32_t, FieldInfo> Fields;

  friend class ProgramPointState;
  friend class PEAResult;
  friend class PEAVisitor;

public:
  AllocationState() : ES(EscapeState::Unknown), LockCount(0) {}

  EscapeState getEscapeState() const { return ES; }
  uint32_t getLockCount() const { return LockCount; }

  bool hasField(uint32_t Offset) const { return Fields.contains(Offset); }
  const FieldInfo *getField(uint32_t Offset) const {
    auto It = Fields.find(Offset);
    return It != Fields.end() ? &It->second : nullptr;
  }
  const DenseMap<uint32_t, FieldInfo> &getAllFields() const { return Fields; }

  bool operator==(const AllocationState &Other) const;

  void mergeFrom(const SmallVector<const AllocationState*> &PredStates,
               const SmallVector<BasicBlock*> &PredBBs,
               AllocID AllocId,
               PEAResult &Result,
               BasicBlock *MergeBB);

private:
  void setEscapeState(EscapeState S) { ES = S; }
  void setLockCount(uint32_t C) { LockCount = C; }
  void incLockCount() { LockCount++; }
  void decLockCount() { if (LockCount > 0) LockCount--; }

  void setField(uint32_t Offset, Value *Val, Type *Ty, bool IsOop) {
    Fields[Offset] = FieldInfo(Val, Ty, IsOop);
  }
};

/// \class AliasInfo
/// \brief Represents a pointer with allocation ID and offset information.
///
/// AliasInfo captures the essential information about where a pointer points to:
/// - Which allocation object (AllocID)
/// - Offset within the object (for field access)
/// - Whether offset is known (PHI merge may lose this information)
///
/// This enables handling:
/// - Chained GEP: gep(gep(obj, 0), 4) -> {AllocId=obj, Offset=0+4=4}
/// - PHI merge of GEPs: phi(gep1, gep2) -> {AllocId=obj, Offset=?, HasOffset=false}
class AliasInfo {
  AllocID AllocId;
  uint32_t Offset;
  bool HasOffset;

public:
  AliasInfo() : AllocId(0), Offset(0), HasOffset(false) {}

  AliasInfo(AllocID Id, uint32_t Off) : AllocId(Id), Offset(Off), HasOffset(true) {}

  static AliasInfo createUnknownOffset(AllocID Id) {
    AliasInfo P;
    P.AllocId = Id;
    P.HasOffset = false;
    return P;
  }

  AllocID getAllocId() const { return AllocId; }
  uint32_t getOffset() const { return Offset; }
  bool hasOffset() const { return HasOffset; }

  /// Check if this is Phantom (unknown allocation)
  bool isPhantom() const { return AllocId == 0; }

  /// Add offset for chained GEP
  AliasInfo addOffset(uint32_t Off) const {
    if (!HasOffset) return *this;
    return AliasInfo(AllocId, Offset + Off);
  }

  /// Merge two pointers
  static AliasInfo merge(const AliasInfo &A, const AliasInfo &B) {
    if (A.AllocId != B.AllocId) return AliasInfo();
    if (A.HasOffset && B.HasOffset && A.Offset == B.Offset) {
      return AliasInfo(A.AllocId, A.Offset);
    }
    return createUnknownOffset(A.AllocId);
  }

  /// Merge multiple pointers
  static AliasInfo merge(ArrayRef<AliasInfo> Infos) {
    if (Infos.empty()) return AliasInfo();

    AliasInfo Result = Infos[0];
    for (size_t i = 1; i < Infos.size(); i++) {
      Result = merge(Result, Infos[i]);
      if (Result.isPhantom()) break;
    }
    return Result;
  }

  bool operator==(const AliasInfo &Other) const {
    return AllocId == Other.AllocId && Offset == Other.Offset && HasOffset == Other.HasOffset;
  }
};

//===----------------------------------------------------------------------===//
// ProgramPointState - State snapshot at a program point (flow-sensitive)
//===----------------------------------------------------------------------===//

/// \class ProgramPointState
/// \brief Flow-sensitive state snapshot at a specific program point.
///
/// ProgramPointState captures the DYNAMIC state of allocations at block
/// entries and particular IR instructions. Unlike the static alias
/// information in Alias map, escape states can change across program
/// points due to control flow and side effects.
///
/// Key Design Principle:
/// ---------------------
/// - Alias information (Instruction → AllocID) is STATIC (SSA property)
/// - Escape state is DYNAMIC (depends on control flow)
///
/// State Components:
/// -----------------
/// AllocationStates: DenseMap<AllocID, AllocationState>
///
/// Each AllocationState tracks complete information for one allocation:
/// EscapeState, LockCount and Fields.
///
/// Flow-Sensitive Example:
/// -----------------------
/// ```java
/// A a = new A();      // State at point 1: NoEscape
/// if (cond) {
///   global = a;       // State at point 2: GlobalEscape
/// } else {
///   use(a);           // State at point 3: NoEscape
/// }
/// ```
///
/// At different program points, the same allocation has different
/// escape states. This enables materialization at escape points while
/// keeping the allocation virtual on non-escaping paths.
class ProgramPointState {
  DenseMap<AllocID, AllocationState> AllocationStates;

  friend class llvm::PartialEscapeAnalysis;
  friend class PEAVisitor;

public:
  ProgramPointState() = default;

  const AllocationState *getAllocState(AllocID AllocId) const {
    auto It = AllocationStates.find(AllocId);
    return It != AllocationStates.end() ? &It->second : nullptr;
  }
  bool hasAllocState(AllocID AllocId) const {
    return AllocationStates.contains(AllocId);
  }

  const DenseMap<AllocID, AllocationState>& getAllAllocationStates() const {
    return AllocationStates;
  }

  EscapeState getEscapeState(AllocID AllocId) const {
    auto *AS = getAllocState(AllocId);
    return AS ? AS->getEscapeState() : EscapeState::Unknown;
  }
  int32_t getLockCount(AllocID AllocId) const {
    auto *AS = getAllocState(AllocId);
    return AS ? AS->getLockCount() : 0;
  }

  bool operator==(const ProgramPointState &Other) const;

  std::unique_ptr<ProgramPointState> copy() const;

private:
  void setEscapeState(AllocID AllocId, EscapeState S) {
    AllocationStates[AllocId].setEscapeState(S);
  }
  void setLockCount(AllocID AllocId, int32_t Count) {
    AllocationStates[AllocId].setLockCount(Count);
  }
  void incLockCount(AllocID AllocId) {
    AllocationStates[AllocId].incLockCount();
  }
  void decLockCount(AllocID AllocId) {
    AllocationStates[AllocId].decLockCount();
  }

  void setField(AllocID AllocId, uint32_t Offset, Value *Val, Type *Ty, bool IsOop) {
    AllocationStates[AllocId].setField(Offset, Val, Ty, IsOop);
  }

  void mergeFrom(const SmallVector<ProgramPointState*> &PredStates,
                 const SmallVector<BasicBlock*> &PredBBs,
                 PEAResult &Result,
                 BasicBlock *MergeBB);
};

//===----------------------------------------------------------------------===//
// VirtualPhiNode - Represents a PHI value for field merging
//===----------------------------------------------------------------------===//

/// \class VirtualPhiNode
/// \brief Represents a virtual PHI node for field value merging.
///
/// VirtualPhiNode is created during state merge when field values differ
/// across control flow paths. It represents the PHI relationship without
/// immediately creating IR. Actual PHI nodes are created lazily during
/// the transformation phase (by PEATransformer).
///
/// Key Properties:
/// --------------
/// - AllocId: The allocation object this PHI belongs to
/// - Offset: The field offset that needs PHI
/// - MergeBB: The merge block where PHI should be created
/// - Inputs: Map from predecessor block to field value
class VirtualPhiNode {
  AllocID AllocId;
  uint32_t Offset;
  BasicBlock *MergeBB;

  DenseMap<BasicBlock *, StoredValueTy> Inputs;

  friend class PEAResult;

public:
  VirtualPhiNode(AllocID Id, uint32_t Off, BasicBlock *BB)
      : AllocId(Id), Offset(Off), MergeBB(BB) {}

  AllocID getAllocId() const { return AllocId; }
  uint32_t getOffset() const { return Offset; }
  BasicBlock *getMergeBB() const { return MergeBB; }

  void addInput(BasicBlock *PredBB, StoredValueTy Val) {
    Inputs[PredBB] = Val;
  }

  bool hasInput(BasicBlock *PredBB) const {
    return Inputs.contains(PredBB);
  }

  StoredValueTy getInput(BasicBlock *PredBB) const {
    auto It = Inputs.find(PredBB);
    return It != Inputs.end() ? It->second : StoredValueTy(static_cast<Value *>(nullptr));
  }

  const DenseMap<BasicBlock *, StoredValueTy> &getInputs() const {
    return Inputs;
  }

  size_t getNumInputs() const {
    return Inputs.size();
  }

  /// Check if this VirtualPhiNode belongs to a specific allocation and field
  bool matches(AllocID Id, uint32_t Off) const {
    return AllocId == Id && Offset == Off;
  }

  /// Create actual PHI IR node in MergeBB
  /// This is called by PEATransformer during the transformation phase
  PHINode *createPHIIR(Type *FieldType) const;
};

//===----------------------------------------------------------------------===//
// LazyObjectBundle - Symbolic description for deoptimization materialization
//===----------------------------------------------------------------------===//

/// \struct LazyObjectBundle
/// \brief Symbolic description for deoptimization materialization (lazy_object).
///
/// Format (similar to Falcon):
/// lazy_object <id> {klass, field_count, [{offset, value}...]}
///
/// Example IR representation:
/// call void @foo() [ "lazy_object"(i32 1, ptr %klass_A,
///                                   i32 8, i32 5,    // field @offset 8 = 5
///                                   i32 16, ptr #2) ] // field @offset 16 -> lazy_object #2
///
/// NOTE: This is used by the optimization pass (PEATransformer), not directly
/// by the analysis. The analysis only provides the data needed to build bundles.
struct LazyObjectBundle {
  AllocID AllocId;

  struct FieldEntry {
    uint32_t Offset;
    Value *FieldValue;
    Type *FieldType;
    bool IsOop;
    AllocID ReferencedAllocId;

    FieldEntry(uint32_t O, Value *V, Type *T, bool IsO, AllocID RefAlloc = 0)
        : Offset(O), FieldValue(V), FieldType(T), IsOop(IsO), ReferencedAllocId(RefAlloc) {}
  };

  SmallVector<FieldEntry, 8> Fields;

  uint32_t getFieldCount() const { return Fields.size(); }
};

//===----------------------------------------------------------------------===//
// PEAResult - Complete PEA result with flow-sensitive states
//===----------------------------------------------------------------------===//

/// \class PEAResult
/// \brief Complete result of Partial Escape Analysis for a function.
///
/// PEAResult combines the STATIC Alias map with DYNAMIC ProgramPointStates
/// to provide a complete analysis result. This separation enables:
///
/// 1. Static alias queries without program point context
/// 2. Dynamic escape state queries at specific program points
/// 3. Materialization point determination for deoptimization
///
/// Architecture Overview:
/// ---------------------
/// ```
/// PEAResult
/// ├── Alias (static)            - Alias relationships
/// │   └── Map<Value*, AliasInfo>
/// │       - Each pointer-producing value maps to its target allocation info
/// │       - SSA property: alias determined at definition, never changes
/// │
/// ├── Allocations               - All allocation objects
/// │   └── vector<unique_ptr<AllocationObject>>
/// │       - AllocationObject (ID=0: PhantomObj, ID>0: real/virtual)
/// │       - ArrayAllocationObject (array allocations)
/// │       - VirtualAllocationObject (PHI-merged allocations)
/// │
/// ├── InstStates (dynamic)      - Flow-sensitive escape states
/// │   └── Map<Instruction*, ProgramPointState>
/// │       └── AllocationStates        - state per allocation
/// │
/// └── BlockStates               - escape states in basic block entries
///     └── Map<BasicBlock*, ProgramPointState>
///
/// Find escape points:
/// ```cpp
/// auto EscapePoints = Result.getEscapePoints(AllocId);
/// // Use DominatorTree in Transformer Pass to compute minimal materialize points
/// ```
///
/// Escape Points vs Materialize Points:
/// -------------------------------------
/// getEscapePoints() returns ALL escape points. Transformer Pass uses
/// DominatorTree to filter dominated points, computing the minimal set
/// of materialize points where real allocation is needed.
class PEAResult {
  // Alias - static alias map: Value -> AliasInfo
  DenseMap<Value *, AliasInfo> Alias;

  // Allocations - all allocation objects, indexes are AllocIDs
  std::vector<std::unique_ptr<AllocationObject>> Allocations;

  // InstStates - dynamic state in key instruction that has effect on escape state
  DenseMap<Instruction *, std::unique_ptr<ProgramPointState>> InstStates;

  // BlockStates - block entry state
  DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> BlockStates;

  std::vector<std::unique_ptr<VirtualPhiNode>> VirtualPhiNodes;

public:
  PEAResult() = default;

  ProgramPointState *getInstState(Instruction *Inst) const;
  bool hasState(Instruction *Inst) const { return InstStates.contains(Inst); }

  ProgramPointState *getBlockState(BasicBlock *BB) const;
  bool hasBlockState(BasicBlock *BB) const { return BlockStates.contains(BB); }

  AllocationObject *getAllocationObject(AllocID Id) const;

  /// Get AliasInfo info for a value
  AliasInfo getAliasInfo(Value *V) const;

  /// Check if value has alias
  bool hasAlias(Value *V) const { return Alias.contains(V); }

  /// Get AllocID for a value
  AllocID getAllocId(Value *V) const {
    auto It = Alias.find(V);
    return It != Alias.end() ? It->second.getAllocId() : 0;
  }

  const AllocationState *getAllocationStateAt(Instruction *I, AllocID AllocId) const;

  SmallVector<Instruction *> getEscapePoints(AllocID AllocId) const;
  SmallVector<Instruction *> getAllEscapePoints() const;

  const auto &allocations() const { return Allocations; }

  SmallVector<AllocationObject *> getTrackedAllocations() const;

  SmallVector<LazyObjectBundle, 4> buildLazyObjectBundles(Instruction *DeoptPoint) const;

  AllocationObject *getPhantomObj() const {
    return Allocations.empty() ? nullptr : Allocations[0].get();
  }

  bool isPhantom(AllocationObject *Obj) const {
    return Obj && Obj->getId() == 0;
  }

  bool isPhantom(AllocID Id) const {
    return Id == 0;
  }

  void print(raw_ostream &OS) const;

private:
  ProgramPointState *createInstState(Instruction *Inst);

  ProgramPointState *createBlockState(BasicBlock *BB);

  VirtualPhiNode *createVirtualPhiNode(AllocID AllocId, uint32_t Offset, BasicBlock *MergeBB);

  AllocationObject *createAllocationObject(Instruction *Source, bool IsArray);

  AllocationObject *createVirtualAllocationObject(PHINode *Phi);

  /// Create alias for a value
  void createAlias(Value *V, AliasInfo P);

  /// Convenience: create alias with known offset
  void createAlias(Value *V, AllocID AllocId, uint32_t Offset) {
    createAlias(V, AliasInfo(AllocId, Offset));
  }

  /// Convenience: create Phantom alias
  void createPhantomAlias(Value *V) {
    createAlias(V, AliasInfo());
  }

  friend class llvm::PartialEscapeAnalysis;
  friend class PEAVisitor;
  friend class AllocationState;
};

//===----------------------------------------------------------------------===//
// PEAVisitor - Instruction visitor for Partial Escape Analysis
//===----------------------------------------------------------------------===//

/// \class PEAVisitor
/// \brief InstVisitor for processing IR instructions during PEA analysis.
///
/// PEAVisitor visits each instruction in the function and updates the
/// escape state based on instruction semantics. It is created and used
/// by PartialEscapeAnalysis during the analysis phase.
///
/// Key Responsibilities:
/// ---------------------
/// - Visit allocation calls (jeandle.new_instance, jeandle.newarray)
/// - Visit field accesses (GEP, Store, Load)
/// - Visit control flow merge (PHI, Select)
/// - Visit escape operations (Return, unknown Call)
/// - Visit synchronization (monitorenter/monitorexit)
class PEAVisitor : public InstVisitor<PEAVisitor> {
  ProgramPointState *State;
  PEAResult *Result;
  DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> *BlockOutStates;

public:
  PEAVisitor() : State(nullptr), Result(nullptr), BlockOutStates(nullptr) {}

  void setState(ProgramPointState *S) { State = S; }
  void setResult(PEAResult *R) { Result = R; }
  PEAResult *getResult() const { return Result; }
  void setBlockOutStates(DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> *BO) {
    BlockOutStates = BO;
  }

  // Visit methods for each instruction type
  void visitCallBase(CallBase &I);
  void visitGetElementPtrInst(GetElementPtrInst &I);
  void visitStoreInst(StoreInst &I);
  void visitLoadInst(LoadInst &I);
  void visitReturnInst(ReturnInst &I);
  void visitPHINode(PHINode &I);
  void visitSelectInst(SelectInst &I);
  void visitInstruction(Instruction &I) {}

  friend class PartialEscapeAnalysis;
};

} // namespace llvm::jeandle

//===----------------------------------------------------------------------===//
// PEAPrinterPass - Printer Pass for PEA Results
//===----------------------------------------------------------------------===//

namespace llvm {

class PEAPrinterPass : public PassInfoMixin<PEAPrinterPass> {
  raw_ostream &OS;

public:
  explicit PEAPrinterPass(raw_ostream &OS) : OS(OS) {}

  LLVM_ABI PreservedAnalyses run(Function &F, FunctionAnalysisManager &FAM);

  static bool isRequired() { return true; }
};

//===----------------------------------------------------------------------===//
// PartialEscapeAnalysis - Function Analysis Pass
//===----------------------------------------------------------------------===//

class PartialEscapeAnalysis : public AnalysisInfoMixin<PartialEscapeAnalysis> {
  friend AnalysisInfoMixin<PartialEscapeAnalysis>;

  LLVM_ABI static AnalysisKey Key;

public:
  using Result = jeandle::PEAResult;

  LLVM_ABI Result run(Function &F, FunctionAnalysisManager &FAM);

private:
  jeandle::PEAVisitor Visitor;

  void processInstruction(Instruction *I,
                          jeandle::ProgramPointState *State);

  void processBlock(BasicBlock *BB,
                    jeandle::ProgramPointState *State);

  void processLoop(Loop *L,
                   DenseMap<BasicBlock *, std::unique_ptr<jeandle::ProgramPointState>> &BlockOutStates,
                   jeandle::PEAResult &Result,
                   LoopInfo &LI,
                   const SmallVector<BasicBlock *> &FullRPO);

  /// Get BasicBlocks RPO(reverse post order) in the Function
  SmallVector<BasicBlock *> getRPOOrder(Function &F);

  /// Merge the BlockInState from predecessor states
  std::unique_ptr<jeandle::ProgramPointState> mergePredecessorStates(
      BasicBlock *BB,
      DenseMap<BasicBlock *, std::unique_ptr<jeandle::ProgramPointState>> &BlockOutStates,
      jeandle::PEAResult &Result);

  /// Get RPO order blocks in a loop, only include blocks exactly in this loop and subloops' header blocks
  SmallVector<BasicBlock *> getLoopBlocksInRPO(Loop *L, LoopInfo &LI, const SmallVector<BasicBlock *> &FullRPO);
};

} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_PARTIAL_ESCAPE_ANALYSIS_H
