//===- LockAnalysis.h - Java monitor analysis helpers ----------*- C++ -*-===//
//
// Copyright (c) 2026, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//
//
// Shared analysis for recognizing Jeandle monitor JavaOps, reasoning about
// local region boundaries, and reconstructing the function-wide monitor stack.
// The analyses do not make coarsening decisions; they describe the IR for the
// transform and its structural verifier.
//
//===----------------------------------------------------------------------===//

#ifndef LLVM_ANALYSIS_JEANDLE_LOCKANALYSIS_H
#define LLVM_ANALYSIS_JEANDLE_LOCKANALYSIS_H

#include "llvm/ADT/ArrayRef.h"
#include "llvm/ADT/DenseMap.h"
#include "llvm/ADT/SmallVector.h"
#include "llvm/IR/Intrinsics.h"
#include "llvm/IR/Value.h"
#include <cstdint>
#include <optional>

namespace llvm {
class BasicBlock;
class CallBase;
class CallInst;
class Function;
class Instruction;
class IntrinsicInst;

namespace jeandle::lock {

class LockStackAnalysis;

enum class LockingMode : uint8_t { Monitor, Thin, Lightweight };

/// A recognized Jeandle monitor enter or exit JavaOp.  Monitor JavaOps have
/// two meaningful operands: the receiver object and the BasicLock slot.
struct MonitorOp {
  CallInst *Call = nullptr;
  Value *Object = nullptr;
  Value *Lock = nullptr;
  LockingMode Mode = LockingMode::Monitor;
  bool IsEnter = false;

  explicit operator bool() const { return Call != nullptr; }
};

/// One monitor exit together with the lifetime.end that closes its slot.
/// Keeping these together avoids parallel vectors whose entries can drift out
/// of sync while candidate discovery walks an exceptional edge.
struct MonitorExit {
  MonitorOp Op;
  IntrinsicInst *LifetimeEnd = nullptr;
};

/// One balanced monitor region.  A region has exactly one entry and may have
/// multiple exits when an invoke leaves the region on its normal or unwind
/// edge.  Current lock coarsening supports several matching exits only in the
/// second region; a first region must have exactly one normal monitor exit.
/// Other paths may leave through deopt/return, but not through a second live
/// unlock.  Multiple first-region normal exits can appear after inlining;
/// supporting them is deferred because every additional live path would need
/// an unlock clone.
///
/// Nested redundant enters are represented as removed operations.  Multiple
/// independent or sibling entries are deliberately not merged into one
/// acquisition: that would require proving that every path acquires the same
/// lock exactly once and that no path can observe one of the removed entries,
/// plus placing unlock clones on every live path.  Sibling entries are common
/// Java, but this shape is backlog work rather than an unsupported-language
/// case; each candidate keeps exactly one retained enter and removes only
/// enters nested inside it.
struct MonitorRegionShape {
  MonitorOp Enter;
  SmallVector<MonitorExit, 2> Exits;
};

/// The common rewrite description shared by every coarsening candidate.
///
/// Exactly one monitor operation is retained and all other monitor operations
/// are redundant.  The transform may discover that shape in either of two
/// ways, but slot-use and deopt auditing, normalization, and the final rewrite
/// must behave identically for both:
///   * RetainedEnter is the acquisition that stays live.
///   * RetainedExits are the only monitor exits that survive.
///   * RemovedMonitorOps contains every redundant enter and exit.
///   * LifetimeMarkersToErase are lifetime markers made stale by removing the
///     corresponding monitor operation.
///   * LifetimeMarkersToKeep are lifetime markers that survive the rewrite and
///     continue to describe a discarded slot through the retained slot.
///   * RegionCalls are calls in the covered CFG whose operands or deopt
///     records may name a discarded BasicLock slot.
struct MonitorRegion {
  MonitorOp RetainedEnter;
  SmallVector<MonitorOp, 2> RetainedExits;
  SmallVector<MonitorOp, 4> RemovedMonitorOps;
  SmallVector<Instruction *, 8> LifetimeMarkersToErase;
  SmallVector<Instruction *, 4> LifetimeMarkersToKeep;
  SmallVector<CallBase *, 8> RegionCalls;
  /// A branch that leaves the coarsened region before the retained exit.
  /// BeforeBranch is the exit immediately preceding the branch in the same
  /// block; it proves the monitor state at the branch.  Point is the deopt call
  /// (or terminator on a plain return path) before which the retained unlock is
  /// inserted.
  struct EarlyExit {
    CallInst *BeforeBranch = nullptr;
    Instruction *Point = nullptr;
  };
  SmallVector<EarlyExit, 4> EarlyExitPoints;

  bool empty() const { return !RetainedEnter || RemovedMonitorOps.empty(); }
};

/// Two balanced monitor regions separated by transparent instructions.
///
/// Current shape limits:
///   * exactly one retained (outermost) enter; sibling/nested enters are not
///     merged into it;
///   * the first region has exactly one *normal* monitor exit.  Additional
///     paths inside the first region may only terminate the frame through
///     deopt/return, where the deopt bundle still records the live monitor;
///   * the second region may have several matching exits (invoke normal and
///     unwind edges, guarded deopt exits) but no second nested enter;
///   * neither region may contain a loop or an entry edge from outside it.
///
/// Supporting several normal exits in either region, or several independent
/// enters, is intentionally deferred.  Sibling enters are common Java, and
/// multiple normal exits appear after inlining; both would require unlock
/// clones on additional live paths, so they are backlog items rather than
/// unsupported-language shapes.
///
/// These are deliberate scope choices, not claims that Java cannot produce
/// the shape.  See the coverage section at the top of LockCoarsening.cpp.
///
/// This candidate form keeps the lexical boundary data needed to validate the
/// shape.  It converts to MonitorRegion through getMonitorRegion() for the
/// common proof and rewrite path.
struct AdjacentRegion {
  MonitorRegionShape First;
  MonitorRegionShape Second;
  SmallVector<Instruction *, 4> BoundaryLifetimeMarkers;
  /// Blocks visited while proving the first region's CFG.  Used to verify that
  /// a cross-block first exit really belongs to this acquisition.
  SmallVector<BasicBlock *, 8> FirstRegionBlocks;
  /// Calls inside the first region that may name its BasicLock slot in a deopt
  /// bundle.  They are audited with the other region calls.
  SmallVector<CallBase *, 4> FirstRegionCalls;
  /// Blocks visited while proving the second region's CFG.  Exits must belong
  /// to this set; a path may also terminate in a deopt that preserves the
  /// retained monitor and therefore needs no cloned unlock.
  SmallVector<BasicBlock *, 8> SecondRegionBlocks;
  /// Calls in the second region whose deopt bundles or ordinary operands may
  /// refer to the discarded BasicLock slot.  They are rewritten by the slot
  /// normalization step.
  SmallVector<CallBase *, 4> SecondRegionCalls;
};

/// A CFG-wide monitor region rooted at one outer enter.  Every path leaving
/// the retained enter reaches a retained exit before terminating; all nested
/// and early redundant monitor operations are removed.  This is the same
/// rewrite description as MonitorRegion; the alias keeps candidate provenance
/// visible at call sites without introducing a second implementation.
using CoveredRegion = MonitorRegion;

/// Adapt the straight-line candidate to the common rewrite description.
MonitorRegion getMonitorRegion(const AdjacentRegion &Region);

/// Recognize a monitor enter/exit call and decode its locking mode.  Returns
/// std::nullopt for calls that are not one of the supported Jeandle monitor
/// JavaOps or for malformed calls with fewer than two operands.
std::optional<MonitorOp> getMonitorOp(Instruction &I);

/// Strip identity-preserving wrappers from a monitor receiver.  The bounded
/// walk is conservative: if the root cannot be reached within the bound, the
/// caller simply gets a less precise value and loses a coarsening opportunity.
Value *stripMonitorIdentity(Value *V);

bool sameMonitorObject(const MonitorOp &A, const MonitorOp &B);
bool sameMonitorLock(const MonitorOp &A, const MonitorOp &B);

bool isLifetimeMarker(const Instruction &I);

/// Whether an instruction may appear between two monitor regions without
/// making the boundary unsafe to cross.  Debug info, lifetime markers, and
/// pure SSA computation are transparent.  Calls, memory operations, PHIs, and
/// terminators are hard boundaries.
bool isBoundaryTransparent(const Instruction &I);

Value *getLifetimePointer(IntrinsicInst &II);

bool isLifetimeFor(Instruction *I, Intrinsic::ID ID, Value *V);

/// Return the nearest preceding monitor JavaOp, or nullopt at block start.
std::optional<MonitorOp> previousMonitorOp(Instruction &From);

/// Return the first non-transparent instruction after From, collecting any
/// lifetime markers skipped along the way in Seen.
Instruction *nextNonTransparent(Instruction &From,
                                SmallVectorImpl<Instruction *> *Seen = nullptr);

/// Find the lifetime.end marker immediately following SecondExit for its lock
/// slot.  A missing marker is allowed and represented by nullptr.
IntrinsicInst *findSecondLifetimeEnd(const MonitorOp &SecondExit);

/// Prove that no discarded BasicLock slot escapes the rewrite.  Its only
/// users may be removed monitor operations, retained exits, audited calls, and
/// the lifetime markers that normalization erases or rewrites.
bool hasOnlyExpectedLockSlotUses(const MonitorRegion &Region,
                                 Value *RetainedLock);

/// Prove that every deopt monitor record naming a discarded BasicLock can be
/// rewritten mechanically.  A malformed bundle, an eliminated monitor, or a
/// monitor owned by a different object is not safe to rewrite.
bool hasOnlyRewritableDeoptLockUses(const MonitorRegion &Region,
                                    ArrayRef<Value *> DiscardedLocks,
                                    Value *RetainedObject);

//===----------------------------------------------------------------------===//
// Global monitor stack analysis
//===----------------------------------------------------------------------===//

/// One live monitor frame.  Object is the normalized receiver identity used by
/// lock coarsening.  An invalid frame (Object == nullptr) can still be a useful
/// nesting sentinel, but cannot prove that an exit matches the top frame.
struct LockStackFrame {
  CallInst *Enter = nullptr;
  Value *Object = nullptr;
  Value *Lock = nullptr;
  LockingMode Mode = static_cast<LockingMode>(0);
  uint32_t BytecodeDepth = 0;

  bool isValid() const { return Enter && Object && Lock; }
  bool operator==(const LockStackFrame &Other) const {
    return Enter == Other.Enter && Object == Other.Object &&
           Lock == Other.Lock && Mode == Other.Mode &&
           BytecodeDepth == Other.BytecodeDepth;
  }
  bool operator!=(const LockStackFrame &Other) const {
    return !(*this == Other);
  }
};

/// Monitor stack facts at one program point.
///
/// Frames contains a known suffix of the dynamic stack.  HasUnknownOuter is
/// set when one or more outer frames may exist but their identities cannot be
/// proven at this point (for example after incompatible CFG joins).  The
/// suffix is always the innermost part of the stack.
struct LockStackState {
  SmallVector<LockStackFrame, 4> Frames;
  bool HasUnknownOuter = false;

  bool empty() const { return Frames.empty() && !HasUnknownOuter; }
  bool unknownOuter() const { return HasUnknownOuter; }
  bool operator==(const LockStackState &Other) const;
  bool operator!=(const LockStackState &Other) const {
    return !(*this == Other);
  }
};

/// A matched monitor region.  An enter may have more than one matching exit
/// when the region has exceptional control-flow edges.
struct LockRegion {
  CallInst *Enter = nullptr;
  SmallVector<CallInst *, 2> Exits;
  LockStackFrame Frame;

  bool hasExit(const CallInst *Exit) const;
};

/// Function-wide monitor stack analysis result.
class LockStackAnalysis {
public:
  explicit LockStackAnalysis(Function &F);

  /// Stack facts immediately before a monitor instruction.  Only monitor
  /// call sites are recorded; other instructions return nullptr.
  const LockStackState *getStateBefore(const Instruction &I) const;

  /// Stack facts immediately after a monitor instruction.
  const LockStackState *getStateAfter(const Instruction &I) const;

  /// Matching region for an enter call site, if its structure was recovered.
  const LockRegion *getRegionForEnter(const CallInst *Enter) const;

  /// Prove the exact local stack shape needed by straight-line lock
  /// coarsening: FirstExit releases the current top, the transparent gap does
  /// not change the stack, SecondEnter becomes the new top, and SecondExit
  /// releases it.  A false result means "do not coarsen this candidate", not
  /// "the function is invalid".
  bool provesAdjacentRegion(const AdjacentRegion &Region) const;

private:
  DenseMap<const Instruction *, LockStackState> StatesBefore;
  DenseMap<const Instruction *, LockStackState> StatesAfter;
  DenseMap<const CallInst *, LockRegion> Regions;
};

} // namespace jeandle::lock
} // namespace llvm

#endif // LLVM_ANALYSIS_JEANDLE_LOCKANALYSIS_H
