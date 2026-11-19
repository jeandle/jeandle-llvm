; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" -jeandle-vm-callback-log=%S/Inputs/class-dynamic-type-check-discard.cblog %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare hotspotcc i1 @jeandle.check_klass_subtype(ptr, ptr) nounwind "gc-leaf-function"
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; A value-based synchronization check makes the VO ineligible. Its mutation-owned
; subtype replacement must be discarded without inserting an extra call.
define i1 @discarded_replacement(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  %valuebased = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  ret i1 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @discarded_replacement(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: @jeandle.check_klass_subtype
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NOT: @jeandle.check_klass_subtype
; CHECK: ret i1 %r

; A dependent field load must keep the original query's SSA value when its
; owner becomes ineligible; it cannot capture the discarded unparented call.
define i1 @discarded_replacement_field_user(ptr %super) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 5 to ptr), i32 24, i1 false)
      to label %second unwind label %unwind
second:
  %box = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 6 to ptr), i32 16, i1 false)
      to label %normal unwind label %unwind
normal:
  %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
  %wide = zext i1 %r to i8
  %cell = getelementptr i8, ptr addrspace(1) %box, i64 8
  store i8 %wide, ptr addrspace(1) %cell, align 1
  %valuebased = call hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) %o)
  %result = load i8, ptr addrspace(1) %cell, align 1
  %answer = icmp ne i8 %result, 0
  ret i1 %answer
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i1 @discarded_replacement_field_user(
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.check_klass_subtype
; CHECK: %r = call hotspotcc i1 @jeandle.check_instanceof(ptr %super, ptr addrspace(1) %o)
; CHECK-NOT: @jeandle.check_klass_subtype
; CHECK: ret i1 %r

!java-method-compilation = !{}
