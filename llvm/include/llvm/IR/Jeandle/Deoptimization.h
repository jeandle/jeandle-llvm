//===- Deoptimization.h - Jeandle Deoptimization Support ------------------===//
//
// Copyright (c) 2025, the Jeandle-LLVM Authors. All Rights Reserved.
//
// Part of the Jeandle-LLVM project, under the Apache License v2.0 with LLVM
// Exceptions. See https://llvm.org/LICENSE.txt for license information.
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//
//===----------------------------------------------------------------------===//

#include "llvm/IR/Jeandle/JeandleUtils.h"
#include <cassert>

#ifndef JEANDLE_DEOPTIMIZATION_H
#define JEANDLE_DEOPTIMIZATION_H

namespace llvm::jeandle {

// Mirror of jvm Deoptimization::DeoptReason and Deoptimization::DeoptAction.
class Deoptimization {
public:
  // What condition caused the deoptimization?
  // Note: Keep this enum in sync. with Deoptimization::_trap_reason_name.
  enum DeoptReason {
    Reason_many = -1, // indicates presence of several reasons
    Reason_none = 0,  // indicates absence of a relevant deopt.
    // Next 8 reasons are recorded per bytecode in DataLayout::trap_bits.
    // This is more complicated for JVMCI as JVMCI may deoptimize to *some*
    // bytecode before the bytecode that actually caused the deopt (with
    // inlining, JVMCI may even deoptimize to a bytecode in another method):
    //  - bytecode y in method b() causes deopt
    //  - JVMCI deoptimizes to bytecode x in method a()
    // -> the deopt reason will be recorded for method a() at bytecode x
    Reason_null_check,  // saw unexpected null or zero divisor (@bci)
    Reason_null_assert, // saw unexpected non-null or non-zero (@bci)
    Reason_range_check, // saw unexpected array index (@bci)
    Reason_class_check, // saw unexpected object class (@bci)
    Reason_array_check, // saw unexpected array class (aastore @bci)
    Reason_intrinsic,   // saw unexpected operand to intrinsic (@bci)
    Reason_bimorphic,   // saw unexpected object class in bimorphic inlining
                        // (@bci)

    // Macro INCLUDE_JVMCI should be 1 if jeandle can run.
    // #if INCLUDE_JVMCI
    Reason_unreached0 = Reason_null_assert,
    Reason_type_checked_inlining = Reason_intrinsic,
    Reason_optimized_type_check = Reason_bimorphic,
    // #endif

    Reason_profile_predicate, // compiler generated predicate moved from
                              // frequent branch in a loop failed

    // recorded per method
    Reason_unloaded,              // unloaded class or constant pool entry
    Reason_uninitialized,         // bad class state (uninitialized)
    Reason_initialized,           // class has been fully initialized
    Reason_unreached,             // code is not reached, compiler
    Reason_unhandled,             // arbitrary compiler limitation
    Reason_constraint,            // arbitrary runtime constraint violated
    Reason_div0_check,            // a null_check due to division by zero
    Reason_age,                   // nmethod too old; tier threshold reached
    Reason_predicate,             // compiler generated predicate failed
    Reason_loop_limit_check,      // compiler generated loop limits check failed
    Reason_speculate_class_check, // saw unexpected object class from type
                                  // speculation
    Reason_speculate_null_check,  // saw unexpected null from type speculation
    Reason_speculate_null_assert, // saw unexpected null from type speculation
    Reason_rtm_state_change,      // rtm state change detected
    Reason_unstable_if,           // a branch predicted always false was taken
    Reason_unstable_fused_if, // fused two ifs that had each one untaken branch.
                              // One is now taken.
    Reason_receiver_constraint, // receiver subtype check failed
    // Macro INCLUDE_JVMCI should be 1 if jeandle can run.
    // #if INCLUDE_JVMCI
    Reason_aliasing, // optimistic assumption about aliasing failed
    Reason_transfer_to_interpreter, // explicit transferToInterpreter()
    Reason_not_compiled_exception_handler,
    Reason_unresolved,
    Reason_jsr_mismatch,
    // #endif

    // Used to define MethodData::_trap_hist_limit where Reason_tenured isn't
    // included
    Reason_TRAP_HISTORY_LENGTH,

    // Reason_tenured is counted separately, add normal counted Reasons above.
    Reason_tenured =
        Reason_TRAP_HISTORY_LENGTH, // age of the code has reached the limit
    Reason_LIMIT,

    // Note:  Reason_RECORDED_LIMIT should fit into 31 bits of
    // DataLayout::trap_bits.  This dependency is enforced indirectly
    // via asserts, to avoid excessive direct header-to-header dependencies.
    // See Deoptimization::trap_state_reason and class DataLayout.
    Reason_RECORDED_LIMIT =
        Reason_profile_predicate, // some are not recorded per bc
  };

  // What action must be taken by the runtime?
  // Note: Keep this enum in sync. with Deoptimization::_trap_action_name.
  enum DeoptAction {
    Action_none,            // just interpret, do not invalidate nmethod
    Action_maybe_recompile, // recompile the nmethod; need not invalidate
    Action_reinterpret,     // invalidate the nmethod, reset IC, maybe recompile
    Action_make_not_entrant,    // invalidate the nmethod, recompile (probably)
    Action_make_not_compilable, // invalidate the nmethod and do not compile
    Action_LIMIT
  };

  enum {
    _action_bits = 3,
    _reason_bits = 5,
    _action_shift = 0,
    _reason_shift = _action_shift + _action_bits,
  };

  static int makeTrapRequest(DeoptReason Reason, DeoptAction Action,
                             int Index = -1) {
    static_assert((1 << _reason_bits) >= Reason_LIMIT && "enough bits");
    static_assert((1 << _action_bits) >= Action_LIMIT && "enough bits");
    int TrapRequest;
    if (Index != -1)
      TrapRequest = Index;
    else
      TrapRequest =
          (~(((Reason) << _reason_shift) + ((Action) << _action_shift)));
    return TrapRequest;
  }
};

class DeoptValueEncoding {
  friend class JeandleCompiledCode;

public:
  // ScalarValueType descriptors use the high bit of their field-count word
  // as an out-of-band marker for a semantic java.lang.* box.  The remaining
  // 31 bits retain the ordinary non-negative i32 field count.
  static constexpr uint32_t BoxedDescriptorFlag = 1u << 31;
  static constexpr uint32_t DescriptorFieldCountMask =
      ~BoxedDescriptorFlag;

  enum DeoptValueType {
    LocalType = 0,
    StackType = 1,
    ArgumentType = 2,
    // A monitor (lock) entry in the "monitor" section of a deopt scope. On the
    // wire a monitor is a 3-location tuple consumed by the HotSpot parser:
    //   <enc(MonitorType, index=K, T_OBJECT), object, basic_lock>
    // where `object` is the locked oop and `basic_lock` is the BasicLock stack
    // slot. The Index field is a monitor-kind discriminant (the frontend, which
    // emits only REAL locks, always uses index=0; the HotSpot parser ignores
    // Index for real locks):
    //   index=0  REAL (non-eliminated) lock. `object` is a live oop (a stack/
    //            register location, or a null constant). MonitorValue is built
    //            with eliminated=false — the lock is genuinely held (e.g. a
    //            re-emitted monitorenter on a materialized VO's OrigAlloc), so
    //            HotSpot relock_objects leaves it alone.
    //   index=1  PEA-ELIMINATED lock on a VIRTUAL object. `object` is the owner
    //            VO's vo-id as an i32 CONSTANT (NOT a live oop) — the parser
    //            resolves it through the record-level vo_map (descriptors live
    //            in the root scope's VO section) to the owner's ObjectValue*,
    //            and builds the MonitorValue with eliminated=true so
    //            relock_objects re-acquires the monitor on the realloc'd owner
    //            (C2/Graal MonitorValue{owner=ObjectValue, eliminated=true}
    //            analog). The basic_lock slot is preserved verbatim;
    //            ObjectSynchronizer::enter initializes it. The PEA transform
    //            emits this form as part of the complete deopt-pool rewrite.
    MonitorType = 3,
    // ScalarValueType encodes a PEA virtual-object (VO) descriptor inside a
    // "deopt" operand bundle so HotSpot can reallocate the object at deopt
    // (C2/Graal scalar-replacement analog). It is emitted ONCE PER VO PER
    // DEOPT POINT. ALL descriptors of a deopt point are placed in the ROOT
    // (outermost) scope's VO section — right AFTER the root's duplicated-BCI
    // marker and BEFORE the root locals — which serves as the deopt-point-
    // level object pool: every descriptor precedes any VORef that references
    // it (the HotSpot parser walks scopes outermost-first and resolves
    // VORefs through a record-level vo_map), mirroring C2's dump_object_pool
    // before create_scope_values and Graal/JVMCI's per-DebugInfo
    // VirtualObject[] pool.
    //
    // On the wire, a ScalarValueType entry is the header of a multi-location
    // sequence read by the HotSpot parser:
    // clang-format off
    //   [enc: ScalarValueType, index=vo_id, basic_type=T_OBJECT(instance)|T_ARRAY]
    //   [klass]        ; i64 constant = raw InstanceKlass/ArrayKlass identity
    //   [field_count]  ; i32 constant = number of (enc,value) field pairs that
    //                   ; follow (non-static fields in InstanceKlass declaration
    //                   ; order; long/double occupy one pair and the HotSpot
    //                   ; parser expands the value to two interpreter slots)
    //   [field 0]      ; (enc(LocalType/StackType, basic_type), value) — parsed
    //   ...            ;   by the existing fill_one_scope_value, so a field's
    //   [field N-1]    ;   value may itself be a VORef referencing another VO
    //                   ;   (cycle/transitive closure) or a live materialized
    //                   ;   oop (OrigAlloc).
    // A field whose value is ANOTHER VO in this deopt point is encoded as a
    // VORef FIELD:
    //   [field_enc]    DeoptValueEncoding(offset, VORefLocalType, T_OBJECT)
    //   [field_value]  i32 constant = the referenced VO's vo-id
    // The parser consumes (3 + 2*field_count) locations for one descriptor.
    // clang-format on
    //
    // The HotSpot parser routes a VORefLocalType FIELD to vo_map (NOT
    // fill_one_scope_value, which would trip ShouldNotReachHere on the non-oop
    // vo-id constant) and uses the referenced VO's ObjectValue as the field's
    // ScopeValue. A scalar field stays enc(LocalType, basic_type) + concrete
    // Value*. Do NOT encode a VO field as a constant oop.
    ScalarValueType = 4,
    OrigPcSlotType = 5,
    MethodType = 6,
    NarrowOopMarkerType = 7,
    // VORefLocalType / VORefStackType mark a locals / stack slot that holds a
    // VO already described by a ScalarValueType descriptor earlier in this
    // deopt point (all descriptors live in the root scope's VO section). The
    // trailing location is the i32 vo_id; the slot's ScopeValue is
    // the ObjectValue built from that descriptor. TWO distinct types (not one
    // VORefType) so the HotSpot parser can route the slot to the correct
    // interpreter array (locals vs expression stack) — the parser routes every
    // entry by encoding type, so collapsing them would misroute a VO-ref that
    // lives in a stack slot (a structural guarantee, not a position proxy).
    // Used so a VO referenced from N slots is described once and referenced by
    // id elsewhere.
    VORefLocalType = 8,
    VORefStackType = 9,
    LastType = VORefStackType + 1
  };
  DeoptValueEncoding(int I, DeoptValueType VT, HotspotBasicType BT)
      : Index(I), ValueTy(VT), BasicTy(BT) {
    // Standard assert.
    assert((ValueTy == LocalType || ValueTy == StackType ||
            ValueTy == MonitorType || ValueTy == ScalarValueType ||
            ValueTy == OrigPcSlotType || ValueTy == MethodType ||
            ValueTy == NarrowOopMarkerType || ValueTy == VORefLocalType ||
            ValueTy == VORefStackType) &&
           "Unsupported value type");
  }

  inline uint64_t encode() {
    // encode format
    // |--- index ---|--- value_type ---|--- basic_type ---|
    // |0          31|32              47|48              63|
    return ((uint64_t)Index << 32) | ((uint64_t)(ValueTy << 16)) |
           (uint64_t)(BasicTy);
  }

  static inline DeoptValueEncoding decode(uint64_t Encode) {
    int Index = (int)(Encode >> 32);
    assert(Index >= 0 && "must be");
    int ValType = (int)((Encode & 0xffff0000UL) >> 16);
    assert(ValType >= 0 && ValType < DeoptValueType::LastType && "must be");
    int BasicTypeVal = (int)((Encode & 0xffffUL));
    assert(BasicTypeVal >= 0 && BasicTypeVal <= HotspotBasicType::T_ILLEGAL &&
           "must be");
    return {Index, (DeoptValueType)(ValType), (HotspotBasicType)(BasicTypeVal)};
  }

  inline int index() const { return Index; }
  inline DeoptValueType valueType() const { return ValueTy; }
  inline HotspotBasicType basicType() const { return BasicTy; }

private:
  int Index;
  DeoptValueType ValueTy;
  HotspotBasicType BasicTy;
};

} // namespace llvm::jeandle

#endif
