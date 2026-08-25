; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, outer-scope STACK slot: a VO is referenced ONLY
; by the ROOT scope's STACK section (enc StackType index=0 T_OBJECT =
; (1<<16)|12 = 65548), not its locals. The JDK parser routes slots by type
; (locals vs expression stack), so the stack-slot rewrite is an independent
; unit: the descriptor goes into the ROOT scope's VO section (after the
; should_reexecute i64 + first duplicated-BCI pair) and the outer-scope
; stack slot is rewritten to a VORefStackType by vo-id.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_stack(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) has NO locals and ONE STACK slot holding %o; the INNERMOST scope
  ; (bci 9) has one i32 local. (i64 393233 = MethodType marker pair
  ; encoding: (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 65548, ptr addrspace(1) %o,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 10, i32 %x) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %o is NeverEscapes (only in the bundle): eliminated and described right
; AFTER THE ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5): header (vo_id=0, ScalarValueType, T_OBJECT):
; (0<<32)|(4<<16)|12 = 262156; klass 100; field_count 1; field (offset 8,
; LocalType/T_INT): (8<<32)|10 = 34359738378 -> %x. The ROOT-scope STACK
; slot becomes a VORefStackType: (0<<32)|(9<<16)|12 = 589836, then i32 0.
; CHECK-LABEL: define void @multiscope_stack(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 589836, i32 0,
; CHECK-SAME: i64 393233, i64 777,
; CHECK-SAME: i64 1, i32 9, i32 9, i64 10, i32 %x) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
