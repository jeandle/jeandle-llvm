//===- DeoptPoolPlanner.h - Semantic deopt object-pool planning -*- C++ -*-===//
//
// Part of the LLVM Project, under the Apache License v2.0 with LLVM Exceptions.
// See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// This file defines a pure graph planner for Jeandle deoptimization object
// pools. It composes the durable legacy descriptor graph with current PEA
// nodes, prunes unreachable nodes, and derives fresh dense wire IDs.
//
// The output is deliberately a semantic graph plan, not the transform-ready
// operand-bundle plan. A later lowering layer must combine it with the parsed
// bundle and produce the complete immutable output-token template held by the
// atomic deopt-pool effect.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_DEOPTPOOLPLANNER_H
#define LLVM_ANALYSIS_JEANDLE_DEOPTPOOLPLANNER_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Jeandle/Deoptimization.h"
#include "llvm/Support/Compiler.h"

#include <cstdint>
#include <limits>
#include <optional>

namespace llvm {
namespace jeandle {
namespace pea {

// Analysis-local identity of a current (PEA-described) virtual object, valid
// only within one planning round.
using CurrentDeoptNodeID = uint32_t;
// Operand index of an exact value cell in the parsed source bundle. The
// planner treats it as an opaque provenance handle for the lowering layer.
using DeoptPoolSemanticCellID = uint32_t;

inline constexpr CurrentDeoptNodeID InvalidCurrentDeoptNodeID =
    std::numeric_limits<CurrentDeoptNodeID>::max();
inline constexpr DeoptPoolSemanticCellID InvalidDeoptPoolSemanticCellID =
    std::numeric_limits<DeoptPoolSemanticCellID>::max();
inline constexpr uint32_t InvalidDeoptPoolWireID =
    std::numeric_limits<uint32_t>::max();

// Which input node table a DeoptPoolNodeRef addresses: Legacy nodes are
// identified by their frontend-assigned wire ID, Current nodes by their
// analysis-local ID. The two ID spaces are unrelated.
enum class DeoptPoolNodeNamespace : uint8_t { Legacy, Current };

// A typed reference to one input pool node. The namespace tag is part of the
// identity because legacy wire IDs and current IDs share the same integers.
struct DeoptPoolNodeRef {
  DeoptPoolNodeNamespace Namespace = DeoptPoolNodeNamespace::Legacy;
  uint32_t ID = 0;

  static DeoptPoolNodeRef legacy(uint32_t WireID) {
    return {DeoptPoolNodeNamespace::Legacy, WireID};
  }
  static DeoptPoolNodeRef current(CurrentDeoptNodeID ID) {
    return {DeoptPoolNodeNamespace::Current, ID};
  }

  bool operator==(const DeoptPoolNodeRef &Other) const {
    return Namespace == Other.Namespace && ID == Other.ID;
  }
};

// SemanticCell identifies the exact value cell in the parsed input bundle.
// It is opaque to the graph planner; the codec/lowering layer may use the
// bundle-relative operand index. Current fields are newly emitted cells and
// therefore use InvalidDeoptPoolSemanticCellID.
//
// ScalarToken is equally opaque. It is a planner-only handle for scalar
// payload identity; lowering must resolve it to its tracked LLVM Value. The
// numeric token itself is never serialized onto the deopt wire.
//
// Offset is the raw heap byte offset of the field (array elements use their
// scaled element offset); it is serialized as the deopt value-encoding index.
// IsReference selects the payload union: a reference field carries a Target
// node ref and is always T_OBJECT, a scalar field carries a ScalarToken and
// its computational BasicType.
struct DeoptPoolFieldInput {
  DeoptPoolSemanticCellID SemanticCell = InvalidDeoptPoolSemanticCellID;
  int64_t Offset = 0;
  HotspotBasicType BasicType = T_ILLEGAL;
  bool IsReference = false;
  uint64_t ScalarToken = 0;
  DeoptPoolNodeRef Target;

  static DeoptPoolFieldInput scalar(DeoptPoolSemanticCellID SemanticCell,
                                    int64_t Offset, HotspotBasicType BasicType,
                                    uint64_t ScalarToken) {
    DeoptPoolFieldInput Field;
    Field.SemanticCell = SemanticCell;
    Field.Offset = Offset;
    Field.BasicType = BasicType;
    Field.ScalarToken = ScalarToken;
    return Field;
  }

  static DeoptPoolFieldInput reference(DeoptPoolSemanticCellID SemanticCell,
                                       int64_t Offset,
                                       DeoptPoolNodeRef Target) {
    DeoptPoolFieldInput Field;
    Field.SemanticCell = SemanticCell;
    Field.Offset = Offset;
    Field.BasicType = T_OBJECT;
    Field.IsReference = true;
    Field.Target = Target;
    return Field;
  }

  bool isReference() const { return IsReference; }
};

// A virtual-object descriptor already present in the frontend's original
// bundle. It is durable input: the planner may prune it as unreachable but
// never alters its shape.
struct LegacyDeoptPoolNode {
  // Frontend-assigned pool ID from the original bundle.
  uint32_t WireID = InvalidDeoptPoolWireID;
  // Raw klass identity (InstanceKlass/ArrayKlass pointer) serialized verbatim.
  uint64_t Klass = 0;
  bool IsArray = false;
  // Preserved only for descriptors produced from a semantic jeandle.box.
  // Klass alone is insufficient because new Integer(...) is an ordinary
  // identity-observing allocation of the same wrapper class.
  bool IsBoxed = false;
  // Fields in wire order.
  SmallVector<DeoptPoolFieldInput, 8> Fields;
};

// CurrentNodes must be supplied in deterministic semantic discovery order.
// ID is analysis-local identity only; the planner never copies it to WireID.
struct CurrentDeoptPoolNode {
  CurrentDeoptNodeID ID = InvalidCurrentDeoptNodeID;
  uint64_t Klass = 0;
  bool IsArray = false;
  // True when this current PEA node came from the semantic jeandle.box op.
  bool IsBoxed = false;
  // False when PEA cannot describe this object on the wire (e.g. an array
  // whose element layout is not canonical). A reachable undescribable node
  // aborts planning and is reported as a fallback seed for the caller to
  // materialize before retrying.
  bool Describable = true;
  SmallVector<DeoptPoolFieldInput, 8> Fields;
};

// Which scope slot a root cell occupies. The kind selects the VORef encoding
// type on the wire (locals and stack slots are distinct types) and the
// occurrence classification at lowering time.
enum class DeoptPoolRootKind : uint8_t { Local, Stack, MonitorOwner };

// A root cell may already be a legacy/current VORef, or it may still be a
// scalar oop cell which an exact-cell overlay reclassifies as a current VO.
// IsReference selects the payload union: a reference root carries a Target
// node ref, a scalar root carries a ScalarToken.
struct DeoptPoolRootInput {
  // Exact source cell of the root's value operand.
  DeoptPoolSemanticCellID SemanticCell = InvalidDeoptPoolSemanticCellID;
  DeoptPoolRootKind Kind = DeoptPoolRootKind::Local;
  bool IsReference = false;
  uint64_t ScalarToken = 0;
  DeoptPoolNodeRef Target;

  static DeoptPoolRootInput scalar(DeoptPoolSemanticCellID SemanticCell,
                                   DeoptPoolRootKind Kind,
                                   uint64_t ScalarToken) {
    DeoptPoolRootInput Root;
    Root.SemanticCell = SemanticCell;
    Root.Kind = Kind;
    Root.ScalarToken = ScalarToken;
    return Root;
  }

  static DeoptPoolRootInput reference(DeoptPoolSemanticCellID SemanticCell,
                                      DeoptPoolRootKind Kind,
                                      DeoptPoolNodeRef Target) {
    DeoptPoolRootInput Root;
    Root.SemanticCell = SemanticCell;
    Root.Kind = Kind;
    Root.IsReference = true;
    Root.Target = Target;
    return Root;
  }

  bool isReference() const { return IsReference; }
};

// Reclassifies the exact scalar oop cell SemanticCell as a reference to the
// current node CurrentTarget. Overlays redirect both reachability and the
// final field/root target without mutating the input nodes.
struct DeoptPoolScalarOverlay {
  DeoptPoolSemanticCellID SemanticCell = InvalidDeoptPoolSemanticCellID;
  CurrentDeoptNodeID CurrentTarget = InvalidCurrentDeoptNodeID;
};

// Complete planner input for one safepoint: the legacy descriptors parsed
// from the original bundle, the current PEA nodes in deterministic discovery
// order, every scope root cell in wire order, and the exact-cell overlays.
struct DeoptPoolPlannerInput {
  SmallVector<LegacyDeoptPoolNode, 8> LegacyNodes;
  SmallVector<CurrentDeoptPoolNode, 8> CurrentNodes;
  SmallVector<DeoptPoolRootInput, 8> Roots;
  SmallVector<DeoptPoolScalarOverlay, 8> Overlays;
};

// Provenance of a final plan node: a kept legacy descriptor or a newly
// described current node.
enum class DeoptPoolNodeOrigin : uint8_t { Legacy, Current };

// One resolved field of a final node. TargetWireID is meaningful iff
// IsReference and holds the target's fresh dense wire ID; otherwise
// ScalarToken carries the scalar payload identity for lowering to resolve.
struct FinalDeoptPoolField {
  // Provenance of a legacy field; InvalidDeoptPoolSemanticCellID for current
  // fields, which are newly emitted and have no source cell.
  DeoptPoolSemanticCellID SemanticCell = InvalidDeoptPoolSemanticCellID;
  int64_t Offset = 0;
  HotspotBasicType BasicType = T_ILLEGAL;
  bool IsReference = false;
  uint64_t ScalarToken = 0;
  uint32_t TargetWireID = InvalidDeoptPoolWireID;

  bool isReference() const { return IsReference; }
};

// One node of the final pool with its fresh dense wire ID. LegacySourceIndex
// indexes the input's LegacyNodes iff Origin is Legacy; CurrentID is the
// analysis-local ID iff Origin is Current. The other one stays invalid.
struct FinalDeoptPoolNode {
  uint32_t WireID = InvalidDeoptPoolWireID;
  uint64_t Klass = 0;
  bool IsArray = false;
  bool IsBoxed = false;
  DeoptPoolNodeOrigin Origin = DeoptPoolNodeOrigin::Legacy;
  unsigned LegacySourceIndex = std::numeric_limits<unsigned>::max();
  CurrentDeoptNodeID CurrentID = InvalidCurrentDeoptNodeID;
  SmallVector<FinalDeoptPoolField, 8> Fields;
};

// A scope root cell whose final value is a reference to the pool node
// TargetWireID. Roots that remain scalar are not part of the plan.
struct FinalDeoptPoolRoot {
  DeoptPoolSemanticCellID SemanticCell = InvalidDeoptPoolSemanticCellID;
  DeoptPoolRootKind Kind = DeoptPoolRootKind::Local;
  uint32_t TargetWireID = InvalidDeoptPoolWireID;
};

// The planner's immutable output: a semantic pool graph with fresh dense
// wire IDs. Nodes are ordered by wire ID — reachable legacy nodes first (in
// input order), then reachable current nodes (in input order). Roots hold
// only the source roots whose final value is a reference, in input order.
// CurrentMembers lists the surviving current IDs in node order. NeedsRewrite
// is false when the plan reproduces the original bundle exactly, letting the
// caller skip the rewrite. Construction is restricted to the planner through
// DeoptPoolPlannerAccess so every instance is a validated plan.
class FinalDeoptPoolGraphPlan {
  friend struct DeoptPoolPlannerAccess;

  SmallVector<FinalDeoptPoolNode, 8> Nodes;
  SmallVector<FinalDeoptPoolRoot, 8> Roots;
  SmallVector<CurrentDeoptNodeID, 8> CurrentMembers;
  bool NeedsRewrite = false;

public:
  FinalDeoptPoolGraphPlan(const FinalDeoptPoolGraphPlan &) = default;
  FinalDeoptPoolGraphPlan(FinalDeoptPoolGraphPlan &&) = default;
  FinalDeoptPoolGraphPlan &operator=(const FinalDeoptPoolGraphPlan &) = default;
  FinalDeoptPoolGraphPlan &operator=(FinalDeoptPoolGraphPlan &&) = default;

  ArrayRef<FinalDeoptPoolNode> nodes() const { return Nodes; }
  ArrayRef<FinalDeoptPoolRoot> roots() const { return Roots; }
  ArrayRef<CurrentDeoptNodeID> currentMembers() const { return CurrentMembers; }
  bool needsRewrite() const { return NeedsRewrite; }

private:
  FinalDeoptPoolGraphPlan() = default;
};

enum class DeoptPoolPlannerErrorCode : uint8_t {
  // Two legacy nodes claim the same frontend wire ID.
  DuplicateLegacyWireID,
  // Two current nodes share an analysis-local ID.
  DuplicateCurrentNodeID,
  // Two input cells map to the same bundle operand index.
  DuplicateSemanticCellID,
  // A legacy field or root cell is InvalidDeoptPoolSemanticCellID.
  InvalidSemanticCellID,
  // A reference targets a node absent from both input tables.
  MissingNodeReference,
  // An overlay names an unknown or non-overlayable cell, targets an unknown
  // current node, or duplicates another overlay.
  InvalidScalarOverlay,
  // A current node's field carries a semantic cell; current fields are newly
  // emitted and have no source cell.
  CurrentFieldHasSemanticCell,
};

// A planner failure. Subject is the offending identity (wire ID, node ID, or
// semantic cell) when the code has one.
struct DeoptPoolPlannerError {
  DeoptPoolPlannerErrorCode Code;
  uint32_t Subject = 0;
};

// Exactly one of three outcomes: Error is set for malformed input;
// FallbackSeeds is non-empty (with no Plan) when reachable current nodes are
// undescribable and must be materialized by the caller before retrying;
// otherwise Plan holds the graph.
struct DeoptPoolPlannerResult {
  std::optional<FinalDeoptPoolGraphPlan> Plan;
  SmallVector<CurrentDeoptNodeID, 4> FallbackSeeds;
  std::optional<DeoptPoolPlannerError> Error;
};

// Plan one safepoint's deopt pool: validate the input, prune nodes
// unreachable from the roots, redirect overlaid scalar cells to their current
// targets, and assign fresh dense wire IDs. Pure: performs no IR mutation and
// its result depends only on Input.
LLVM_ABI DeoptPoolPlannerResult
planDeoptPool(const DeoptPoolPlannerInput &Input);

} // namespace pea
} // namespace jeandle
} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_DEOPTPOOLPLANNER_H
