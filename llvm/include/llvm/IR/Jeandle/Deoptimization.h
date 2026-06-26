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
  enum DeoptValueType {
    LocalType = 0,
    StackType = 1,
    ArgumentType = 2,
    MonitorType = 3,
    ScalarValueType = 4,
    OrigPcSlotType = 5,
    MethodType = 6,
    NarrowOopMarkerType = 7,
    LastType = NarrowOopMarkerType + 1
  };
  DeoptValueEncoding(int I, DeoptValueType VT, HotspotBasicType BT)
      : Index(I), ValueTy(VT), BasicTy(BT) {
    // Standard assert.
    assert((ValueTy == LocalType || ValueTy == StackType ||
            ValueTy == MonitorType || ValueTy == OrigPcSlotType ||
            ValueTy == MethodType || ValueTy == NarrowOopMarkerType) &&
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
