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

public:
  static void setEnabled(bool Val) { Enabled = Val; }
  static bool isEnabled() { return Enabled; }

  static void setMaxArrayLength(uint32_t Val) { MaxArrayLength = Val; }
  static uint32_t getMaxArrayLength() { return MaxArrayLength; }
};

enum class EscapeState : uint8_t {
  Unknown,
  NoEscape,
  GlobalEscape
};

enum class PEANodeType : uint8_t {
  Allocation,       // Represents an allocation (object or array)
  Pointer,          // Represents a pointer/alias
  Field             // Represents a field access
};

class PEANode;
class AllocationNode;
class ArrayAllocationNode;
class PointerNode;
class FieldNode;
class AllocationState;
class VirtualPhiMap;
struct LazyObjectBundle;

//===----------------------------------------------------------------------===//
// PEANode - Base class for all PEA nodes
//===----------------------------------------------------------------------===//

/// \class PEANode
/// \brief Base class for all nodes in the Points-To Graph (PTG).
///
/// PEANode is the abstract base class for the three node types in the
/// connection graph structure, inspired by HotSpot C2's escape analysis:
///
/// - AllocationNode: Represents an allocation site (object or array)
/// - PointerNode:    Represents a pointer variable or alias
/// - FieldNode:      Represents a field access (GEP in LLVM IR)
///
/// Node Relationships:
/// -------------------
/// Each PEANode maintains two directional node lists:
///
/// - _Targets: Target nodes - "what this node points to" (outgoing)
/// - _Sources: Source nodes - "what points to this node" (incoming)
///
/// Node relationship semantics vary by node type:
///
/// | From           | To             | Relation     | Meaning                       | Example                | Representation |
/// |----------------|----------------|--------------|-------------------------------|------------------------|----------------|
/// | PointerNode    | AllocationNode | PointsTo     | Pointer points to allocation  | p = new T()            | p -P> T        |
/// | PointerNode    | PointerNode    | Deferred     | Pointer copies another pointer| p = q                  | p -D> q        |
/// | PointerNode    | FieldNode      | Deferred     | Pointer loaded from field     | p = q.f                | p -D> f        |
/// | FieldNode      | AllocationNode | PointsTo     | Field stores allocation ref   | p.f = new T()          | f -P> T        |
/// | FieldNode      | PointerNode    | Deferred     | Field stores pointer ref      | p.f = q                | f -D> q        |
/// | AllocationNode | FieldNode      | Field        | Allocation owns this field    | p = new T(); p.f       | T -F> f        |
///
/// Base Node Marking:
/// ------------------
/// When a PointerNode serves as the base of a FieldNode (e.g., `p.f`),
/// the PointerNode's Sources contains a tagged pointer to mark this as
/// a "base source" rather than a normal PointsTo relation.
///
/// | From           | To             | Relation     | Meaning                       | Example                | Representation |
/// |----------------|----------------|--------------|-------------------------------|------------------------|----------------|
/// | FieldNode      | PointerNode    | Base         | Field bases at pointer ref    | p.f                    | f -B> p        |
///
/// The tagging uses the lowest bit of the pointer address:
/// - Normal pointer (bit 0 = 0): Regular PointsTo/Deferred relation
/// - Tagged pointer (bit 0 = 1): Base relation (PointerNode → FieldNode)
///
/// This technique exploits memory alignment (all valid addresses have
/// bit 0 = 0) and is consistent with HotSpot C2's implementation.
///
/// SSA Property:
/// -------------
/// In LLVM IR with SSA form, each IR Value has a single definition.
/// Therefore, the pointing relationships are STATIC and do not change
/// across different program points. This allows alias information to
/// be stored in the static PointsToGraph rather than flow-sensitive
/// ProgramPointState.
///
/// Reference: HotSpot C2 escape.hpp, escape.cpp
class PEANode {
protected:
  PEANodeType NodeType;
  Value *IRValue = nullptr;
  uint32_t NodeId;

  SmallVector<PEANode *, 4> Targets;
  SmallVector<PEANode *, 4> Sources;

  void addTarget(PEANode *N) {
    if (!hasTarget(N))
      Targets.push_back(N);
  }

  void addSource(PEANode *N) {
    if (!hasSource(N))
      Sources.push_back(N);
  }

  void addBaseSource(FieldNode *F) {
    PEANode *Tagged = (PEANode *)((uintptr_t)F | 1);
    if (!hasSource(Tagged))
      Sources.push_back(Tagged);
  }

  friend class PointsToGraph;

public:
  PEANode(PEANodeType T, Value *V, uint32_t Id)
      : NodeType(T), IRValue(V), NodeId(Id) {}
  virtual ~PEANode() = default;

  PEANodeType getType() const { return NodeType; }
  Value *getIRValue() const { return IRValue; }
  uint32_t getId() const { return NodeId; }

  bool isAllocation() const { return NodeType == PEANodeType::Allocation; }
  bool isPointer() const { return NodeType == PEANodeType::Pointer; }
  bool isField() const { return NodeType == PEANodeType::Field; }

  AllocationNode *asAllocation();
  PointerNode *asPointer();
  FieldNode *asField();

  const SmallVector<PEANode *, 4> &getTargets() const { return Targets; }
  const SmallVector<PEANode *, 4> &getSources() const { return Sources; }

  bool hasTarget(PEANode *N) const { return llvm::is_contained(Targets, N); }
  bool hasSource(PEANode *N) const { return llvm::is_contained(Sources, N); }

  static bool isBaseUse(PEANode *N) {
    return ((uintptr_t)N & 1);
  }

  static FieldNode *getBaseUseNode(PEANode *N) {
    return ((uintptr_t)N & 1) ? (FieldNode *)((uintptr_t)N & ~1) : nullptr;
  }
};

//===----------------------------------------------------------------------===//
// AllocationNode - Represents an allocation site (object)
//===----------------------------------------------------------------------===//

class AllocationNode : public PEANode {
  /// TODO(PEA-Deopt): Add Klass for deoptimization materialization
  /// - uintptr_t Klass = 0; (from jeandle.new_instance argument)
  /// - Used to reconstruct virtual object when deoptimization occurs
  /// - lazy_object bundle format: {alloc_id, klass, field_count, field_values...}

  // uintptr_t Klass = 0;  // TODO: implement after type analysis is stable

public:
  AllocationNode(Value *V, uint32_t Id)
      : PEANode(PEANodeType::Allocation, V, Id) {}

  virtual ~AllocationNode() = default;

  virtual bool isArrayAllocation() const { return false; }

  /// TODO(PEA-Deopt): Add Klass getter/setter

  // uintptr_t getKlass() const { return Klass; }
  // void setKlass(uintptr_t K) { Klass = K; }
};

//===----------------------------------------------------------------------===//
// ArrayAllocationNode - Represents an array allocation site
//===----------------------------------------------------------------------===//

class ArrayAllocationNode : public AllocationNode {
  /// Only array allocations with a statically known size can be processed by Partial Escape Analysis.
  /// In order to limit the overhead introduced by Partial Escape Analysis, only arrays up to a
  /// configurable maximum size, which defaults to 32, are processed
  
  // 0=dynamic, ≤32=optimizable, >32=large
  uint32_t Length = 0;

public:
  ArrayAllocationNode(Value *V, uint32_t Id)
      : AllocationNode(V, Id) {}

  uint32_t getLength() const { return Length; }
  void setLength(uint32_t L) { Length = L; }

  bool isArrayAllocation() const override { return true; }
};

//===----------------------------------------------------------------------===//
// PointerNode - Represents a pointer/alias to allocations or fields
//===----------------------------------------------------------------------===//

class PointerNode : public PEANode {
public:
  PointerNode(Value *V, uint32_t Id)
      : PEANode(PEANodeType::Pointer, V, Id) {}

  const SmallVector<PEANode*, 4>& getTargets() const { return Targets; }
};

//===----------------------------------------------------------------------===//
// FieldNode - Represents a field of an allocation
//===----------------------------------------------------------------------===//

class FieldNode : public PEANode {
  uint32_t Offset = 0;
  bool IsOop = false;

  SmallVector<PEANode *, 4> Bases;

  friend class PointsToGraph;

public:
  FieldNode(Value *V, uint32_t Id)
      : PEANode(PEANodeType::Field, V, Id) {}

  uint32_t getOffset() const { return Offset; }
  bool isOop() const { return IsOop; }

  size_t baseCount() const { return Bases.size(); }
  PEANode *base(size_t i) const { return Bases[i]; }
  const SmallVector<PEANode *, 4> &getBases() const { return Bases; }

  bool hasBase(PEANode *B) const { return llvm::is_contained(Bases, B); }

private:
  void setOffset(uint32_t O) { Offset = O; }
  void setOop(bool O) { IsOop = O; }

  void addBase(PEANode *B) {
    if (B && !hasBase(B))
      Bases.push_back(B);
  }
};

struct FieldInfo {
  Value *StoredValue;
  Type *FieldType;
  bool IsOop;

  FieldInfo() : StoredValue(nullptr), FieldType(nullptr), IsOop(false) {}
  FieldInfo(Value *V, Type *T, bool O) : StoredValue(V), FieldType(T), IsOop(O) {}
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
class AllocationState {
  static constexpr int32_t LOCK_COUNT_UNKNOWN = -1;

  EscapeState ES;
  int32_t LockCount;

  DenseMap<uint32_t, FieldInfo> Fields;

  friend class ProgramPointState;
  friend class PEAResult;

public:
  AllocationState() : ES(EscapeState::Unknown), LockCount(0) {}

  EscapeState getEscapeState() const { return ES; }
  int32_t getLockCount() const { return LockCount; }

  bool hasField(uint32_t Offset) const { return Fields.contains(Offset); }
  const FieldInfo *getField(uint32_t Offset) const {
    auto It = Fields.find(Offset);
    return It != Fields.end() ? &It->second : nullptr;
  }
  const DenseMap<uint32_t, FieldInfo> &getAllFields() const { return Fields; }

  bool operator==(const AllocationState &Other) const;

  void mergeFrom(const AllocationState &Other, uint32_t AllocId,
                 VirtualPhiMap &PhiMap, BasicBlock *MergeBB, BasicBlock *PredBB);

private:
  void setEscapeState(EscapeState S) { ES = S; }
  void setLockCount(int32_t C) { LockCount = C; }
  void incLockCount() { if (LockCount >= 0) LockCount++; }
  void decLockCount() { if (LockCount > 0) LockCount--; }

  void setField(uint32_t Offset, Value *Val, Type *Ty, bool IsOop) {
    Fields[Offset] = FieldInfo(Val, Ty, IsOop);
  }
};

//===----------------------------------------------------------------------===//
// ProgramPointState - State snapshot at a program point (flow-sensitive)
//===----------------------------------------------------------------------===//

/// \class ProgramPointState
/// \brief Flow-sensitive state snapshot at a specific program point.
///
/// ProgramPointState captures the DYNAMIC state of allocations at block
/// entries and particular IR instruction. Unlike the static alias 
/// information in PointsToGraph, escape states can change across program 
/// points due to control flow and side effects.
///
/// Key Design Principle:
/// ---------------------
/// - Alias information (pointer → allocation) is STATIC (SSA property)
/// - Escape state is DYNAMIC (depends on control flow)
///
/// State Components:
/// -----------------
/// AllocationStates: DenseMap<AllocId, AllocationState>
///
/// Each AllocationState tracks complete information for one allocation:
/// 1. EscapeState: Dynamic escape status
///    - Unknown:      Initial state, not yet analyzed
///    - NoEscape:     Allocation is confined, can be scalar-replaced
///    - GlobalEscape: Allocation escapes globally (stored to global field,
///                    returned, passed to unknown function, etc.)
///
/// 2. LockCount: Synchronized lock count for lock elimination
///    - Tracks nested synchronized blocks on same object
///    - Enables lock elimination when count reaches zero
///
/// 3. Fields: DenseMap<Offset, FieldInfo> for scalar replacement
///    - Tracks field values (both pointer and primitive types)
///    - Enables store-load forwarding for scalar replacement
///    - Stores values needed for deoptimization materialization (lazy_object)
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
  Instruction *Inst = nullptr;

  DenseMap<uint32_t, AllocationState> AllocationStates;

  friend class llvm::PartialEscapeAnalysis;

public:
  ProgramPointState(Instruction *I = nullptr) : Inst(I) {}

  Instruction *getInstruction() const { return Inst; }

  const AllocationState *getAllocState(uint32_t AllocId) const {
    auto It = AllocationStates.find(AllocId);
    return It != AllocationStates.end() ? &It->second : nullptr;
  }
  bool hasAllocState(uint32_t AllocId) const {
    return AllocationStates.contains(AllocId);
  }

  EscapeState getEscapeState(uint32_t AllocId) const {
    auto *AS = getAllocState(AllocId);
    return AS ? AS->getEscapeState() : EscapeState::Unknown;
  }
  int32_t getLockCount(uint32_t AllocId) const {
    auto *AS = getAllocState(AllocId);
    return AS ? AS->getLockCount() : 0;
  }

  bool operator==(const ProgramPointState &Other) const;
  ProgramPointState &operator=(const ProgramPointState &Other);

  std::unique_ptr<ProgramPointState> copy() const;

private:
  void setInstruction(Instruction *I) { Inst = I; }

  void setEscapeState(uint32_t AllocId, EscapeState S) {
    AllocationStates[AllocId].setEscapeState(S);
  }
  void setLockCount(uint32_t AllocId, int32_t Count) {
    AllocationStates[AllocId].setLockCount(Count);
  }
  void incLockCount(uint32_t AllocId) {
    AllocationStates[AllocId].incLockCount();
  }
  void decLockCount(uint32_t AllocId) {
    AllocationStates[AllocId].decLockCount();
  }

  void setField(uint32_t AllocId, uint32_t Offset, Value *Val, Type *Ty, bool IsOop) {
    AllocationStates[AllocId].setField(Offset, Val, Ty, IsOop);
  }

  void mergeFrom(const ProgramPointState *Other, VirtualPhiMap &PhiMap, BasicBlock *MergeBB, BasicBlock *PredBB);
};

//===----------------------------------------------------------------------===//
// PointsToGraph - Static structure of allocations and pointers
//===----------------------------------------------------------------------===//

/// \class PointsToGraph
/// \brief Static connection graph representing alias and pointing relationships.
///
/// PointsToGraph is a STATIC data structure that describes all pointing
/// relationships in a function. It is analogous to HotSpot C2's
/// ConnectionGraph and Graal's VirtualState structure.
///
/// Key Property:
/// -------------
/// The graph is STATIC because LLVM IR is in SSA form:
/// - Each IR Value is defined exactly once
/// - A pointer's target(s) are determined at definition and never change
/// - Alias information does not vary across program points
///
/// This is different from escape states which are flow-sensitive.
///
/// Node Types:
/// ----------
/// - AllocationNode: Created for each allocation call (jeandle.new_instance,
///                    jeandle.newarray)
/// - PointerNode:    Created for pointer variables (PHI, BitCast, Load, etc.)
/// - FieldNode:      Created for each unique GEP instruction
///
/// Deferred Edge Propagation:
/// -------------------------
/// Initially, many edges are Deferred (PointerNode → PointerNode/FieldNode).
/// After building the graph, propagateReferences() iteratively propagates
/// these to convert Deferred edges into PointsTo edges:
///
/// ```
/// p1 = new A();     // Alloc1
/// p2 = p1;          // Deferred: p2 → p1
/// p3 = p2;          // Deferred: p3 → p2
///
/// After propagation:
/// p1 → Alloc1       // PointsTo
/// p2 → Alloc1       // PointsTo (propagated from p1)
/// p3 → Alloc1       // PointsTo (propagated from p2)
/// ```
///
/// Value-to-Node Mapping:
/// ---------------------
/// ValueToNode maps each IR Value to its corresponding PEANode:
/// - Allocation call → AllocationNode
/// - GEP instruction → FieldNode
/// - PHI/BitCast/Load → PointerNode
///
/// This enables quick lookup during analysis and optimization phases.
class PointsToGraph {
  std::vector<std::unique_ptr<AllocationNode>> Allocations;
  std::vector<std::unique_ptr<PointerNode>> Pointers;
  std::vector<std::unique_ptr<FieldNode>> Fields;

  DenseMap<Value *, PEANode *> ValueToNode;

  uint32_t NextAllocId = 0;
  uint32_t NextPtrId = 0;
  uint32_t NextFieldId = 0;

  /// PhantomObj - A special allocation node representing all unknown/external objects.
  ///
  /// Inspired by HotSpot C2's phantom_object, PhantomObj represents objects whose
  /// origin cannot be traced within the current function:
  /// - Global variables and static fields
  /// - Function parameters from external callers
  /// - Objects loaded from untracked addresses
  /// - Results of unknown function calls
  ///
  /// Any pointer loaded from an untracked address (e.g., global variable) is
  /// treated as pointing to PhantomObj. PhantomObj is always considered GlobalEscape.
  ///
  /// FieldNodes can also be created with PhantomObj as their base, preserving
  /// offset information for field accesses on unknown objects.
  AllocationNode *PhantomObj = nullptr;

  friend class llvm::PartialEscapeAnalysis;

public:
  AllocationNode *getAllocation(uint32_t Id) const;
  AllocationNode *getAllocationForValue(Value *V) const;
  PointerNode *getPointerForValue(Value *V) const;
  FieldNode *getFieldForValue(Value *V) const;
  PEANode *getNodeForValue(Value *V) const;

  bool hasAllocationForValue(Value *V) const { return getAllocationForValue(V) != nullptr; }
  bool hasNodeForValue(Value *V) const { return ValueToNode.contains(V); }

  AllocationNode *getPhantomObj() const { return PhantomObj; }
  bool isPhantom(AllocationNode *Alloc) const { return Alloc == PhantomObj; }

  const std::vector<std::unique_ptr<AllocationNode>> &allocations() const { return Allocations; }
  const std::vector<std::unique_ptr<PointerNode>> &pointers() const { return Pointers; }
  const std::vector<std::unique_ptr<FieldNode>> &fields() const { return Fields; }

  size_t allocationCount() const { return Allocations.size(); }
  bool empty() const { return Allocations.empty(); }

  SmallVector<AllocationNode *> pointsTo(PEANode *Node);

private:
  void addBase(PEANode *From, FieldNode *To);
  void addEdge(PEANode *From, PEANode *To);
  void removeEdge(PEANode *From, PEANode *To);

  /// Create an AllocationNode representing an allocation site or phantom object.
  /// The following Insts will create an AllocationNode:
  /// - PhantomObj (Alloc#0, globally escaped object such as static global field)
  /// - call jeandle.new_instance (object allocation)
  /// - call jeandle.newarray (array allocation)
  AllocationNode *createAllocation(CallBase *Call, bool IsArray);

  /// Create a PointerNode which points to Target.
  /// The following Insts will create a PointerNode:
  /// - CallInst (jeandle.new_instance/newarray returns)
  /// - BitCastInst (type conversion)
  /// - LoadInst (loading pointer value)
  /// - PHINode (control flow merge)
  /// - SelectInst (conditional selection)
  PointerNode *createPointer(Value *V, PEANode *Target);

  /// Create a FieldNode representing a field access via GEP.
  /// The following Insts will create a FieldNode:
  /// - GetElementPtrInst
  FieldNode *createField(GetElementPtrInst *GEP, PEANode *Base, uint32_t Offset);

  void setPhantomObj(AllocationNode *Alloc) { PhantomObj = Alloc; }

  void propagateReferences();
};

//===----------------------------------------------------------------------===//
// VirtualPhiMap - Pending PHI nodes for field value merging
//===----------------------------------------------------------------------===//

/// \class VirtualPhiMap
/// \brief Tracks pending PHI nodes for field value merging across control flow.
///
/// During state merge, when field values differ across paths, we record the
/// PHI relationship without immediately creating IR. PHI nodes are created
/// lazily during the transformation phase (by PEATransformer).
///
/// - PendingPHIs: Each block's map from (AllocId, Offset) to list of (PredBB, Value)
///
/// Materialization happens in optimization pass, not during analysis
class VirtualPhiMap {
  DenseMap<BasicBlock *,
           DenseMap<std::pair<uint32_t, uint32_t>,
                    DenseMap<BasicBlock *, Value *>>> PendingPHIs;

public:
  void addPendingPhi(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset, BasicBlock *PredBB, Value *Val);

  bool hasPendingPhi(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset) const;

  Value *getPendingValue(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset, BasicBlock *PredBB) const;

  const DenseMap<BasicBlock *, Value *> *
  getPendingInputs(BasicBlock *MergeBB, uint32_t AllocId, uint32_t Offset) const;

  void clear() { PendingPHIs.clear(); }
  bool empty() const { return PendingPHIs.empty(); }
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
  uint32_t AllocId;

  struct FieldEntry {
    uint32_t Offset;
    Value *FieldValue;
    Type *FieldType;
    bool IsOop;
    uint32_t ReferencedAllocId;

    FieldEntry(uint32_t O, Value *V, Type *T, bool IsO, uint32_t RefAlloc = 0)
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
/// PEAResult combines the STATIC PointsToGraph with DYNAMIC ProgramPointStates
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
/// ├── PointsToGraph (static)    - Alias relationships, node structure
/// │   ├── AllocationNodes       - All allocation sites
/// │   ├── PointerNodes          - All pointer variables
/// │   ├── FieldNodes            - All field accesses
/// │   └── ValueToNode mapping   - IR Value → PEANode lookup
/// │
/// ├── States (dynamic)          - Flow-sensitive escape states
/// │   └── Map<Instruction*, ProgramPointState>
/// │       └── AllocationStates        - state per allocation
/// │
/// └── BlockStates               - escape states in basic block entries
///     └── Map<BasicBlock*, ProgramPointState>
/// ```
///
/// Usage Patterns:
/// --------------
/// Query escape state at a program point:
/// ```cpp
/// if (Result.isNoEscapeAt(Inst, Alloc)) {
///   // Can scalar-replace this allocation at this point
/// }
/// ```
///
/// Find materialization points:
/// ```cpp
/// auto Points = Result.getMaterializePoints(AllocId);
/// // These are the instructions where allocation must be materialized
/// ```
///
/// Materialization Points:
/// ----------------------
/// A materialization point is where a virtual allocation becomes real:
/// - Before escape: GlobalEscape state requires real allocation
/// - At deoptimization: Virtual objects must be reconstructed
///
/// getMaterializePoints() returns all instructions where an allocation
/// needs to be materialized, enabling the transformer pass to insert
/// proper allocation and initialization code.
class PEAResult {
  // Graph - static points-to graph records alias information
  PointsToGraph Graph;

  // States - dynamic state in key instruction that has effect on escape state
  DenseMap<Instruction *, std::unique_ptr<ProgramPointState>> States;

  // BlockStates - block entry state
  DenseMap<BasicBlock *, std::unique_ptr<ProgramPointState>> BlockStates;

  VirtualPhiMap PhiMap;

public:
  PEAResult() = default;

  ProgramPointState *getState(Instruction *Inst) const;
  bool hasState(Instruction *Inst) const { return States.contains(Inst); }

  ProgramPointState *getBlockState(BasicBlock *BB) const;
  bool hasBlockState(BasicBlock *BB) const { return BlockStates.contains(BB); }

  AllocationNode *getAllocation(uint32_t Id) const { return Graph.getAllocation(Id); }
  AllocationNode *getAllocationForValue(Value *V) const { return Graph.getAllocationForValue(V); }

  EscapeState getEscapeStateAt(Instruction *I, uint32_t AllocId) const;
  EscapeState getEscapeStateAt(Instruction *I, AllocationNode *Alloc) const;

  int32_t getLockCountAt(Instruction *I, uint32_t AllocId) const;

  SmallVector<Instruction *> getMaterializePoints(uint32_t AllocId) const;
  SmallVector<Instruction *> getAllMaterializePoints() const;

  bool isNoEscapeAt(Instruction *I, AllocationNode *Alloc) const {
    return getEscapeStateAt(I, Alloc) == EscapeState::NoEscape;
  }

  const auto &allocations() const { return Graph.allocations(); }

  SmallVector<AllocationNode *> getTrackedAllocations() const;

  Value *getFieldValueAt(Instruction *I, uint32_t AllocId, uint32_t Offset) const;

  const AllocationState *getAllocationStateAt(Instruction *I, uint32_t AllocId) const;

  SmallVector<LazyObjectBundle, 4>
  buildLazyObjectBundles(Instruction *DeoptPoint) const;

  const VirtualPhiMap &getPhiMap() const { return PhiMap; }

private:
  ProgramPointState *createState(Instruction *Inst);

  ProgramPointState *createBlockState(BasicBlock *BB);

  friend class llvm::PartialEscapeAnalysis;
};

inline AllocationNode *PEANode::asAllocation() {
  assert(isAllocation());
  return static_cast<AllocationNode *>(this);
}

inline PointerNode *PEANode::asPointer() {
  assert(isPointer());
  return static_cast<PointerNode *>(this);
}

inline FieldNode *PEANode::asField() {
  assert(isField());
  return static_cast<FieldNode *>(this);
}

} // namespace llvm::jeandle

//===----------------------------------------------------------------------===//
// PartialEscapeAnalysis - Function Analysis Pass
//===----------------------------------------------------------------------===//

namespace llvm {

class PartialEscapeAnalysis : public AnalysisInfoMixin<PartialEscapeAnalysis> {
  friend AnalysisInfoMixin<PartialEscapeAnalysis>;

  LLVM_ABI static AnalysisKey Key;

public:
  using Result = jeandle::PEAResult;

  LLVM_ABI Result run(Function &F, FunctionAnalysisManager &FAM);

private:
  class PEAVisitor : public InstVisitor<PEAVisitor> {
    jeandle::ProgramPointState *State;
    jeandle::PEAResult *Result;

   public:
    PEAVisitor() : State(nullptr), Result(nullptr) {}

    void setState(jeandle::ProgramPointState *S) { State = S; }
    void setResult(jeandle::PEAResult *R) { Result = R; }

    void visitCallBase(CallBase &I);
    void visitGetElementPtrInst(GetElementPtrInst &I);
    void visitStoreInst(StoreInst &I);
    void visitLoadInst(LoadInst &I);
    void visitReturnInst(ReturnInst &I);
    void visitPHINode(PHINode &I);
    void visitSelectInst(SelectInst &I);
    void visitInstruction(Instruction &I) {}
  };

  PEAVisitor Visitor;

  void processInstruction(Instruction *I,
                          jeandle::ProgramPointState *State,
                          jeandle::PEAResult &Result);

  void processBlock(BasicBlock *BB,
                    jeandle::ProgramPointState *State,
                    jeandle::PEAResult &Result);

  void processLoop(Loop *L,
                   DenseMap<BasicBlock *, std::unique_ptr<jeandle::ProgramPointState>> &BlockOutStates,
                   jeandle::PEAResult &Result,
                   LoopInfo &LI,
                   const SmallVector<BasicBlock *> &FullRPO);

  /// Get BasicBlocks RPO(reverse post order) in the Function
  SmallVector<BasicBlock *> getRPOOrder(Function &F);

  /// Merge the BlockInState form predecessor states
  std::unique_ptr<jeandle::ProgramPointState> mergePredecessorStates(
      BasicBlock *BB,
      DenseMap<BasicBlock *, std::unique_ptr<jeandle::ProgramPointState>> &BlockOutStates,
      jeandle::PEAResult &Result);

  /// Get RPO order blocks in a loop, only include blocks exactly in this loop and subloops' header blocks
  SmallVector<BasicBlock *> getLoopBlocksInRPO(Loop *L, LoopInfo &LI, const SmallVector<BasicBlock *> &FullRPO);
};

} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_PARTIAL_ESCAPE_ANALYSIS_H
