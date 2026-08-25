; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, three scopes, middle-scope reference: a VO is
; referenced ONLY by the MIDDLE scope's locals (bci 5), between the root
; (bci 3) and the innermost (bci 9) scopes. The descriptor is emitted into
; the ROOT scope's VO section (right after the FIRST duplicated-BCI pair —
; the deopt-point-level object pool) and the middle-scope slot is rewritten
; to a VORef by vo-id.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @multiscope_three(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; Three-scope bundle: ROOT (bci 3, preceded by its should_reexecute i64)
  ; has one i32 local; MIDDLE (bci 5)
  ; references %o in its locals; INNERMOST (bci 9) has one i32 local.
  ; (i64 393233 = MethodType marker pair encoding: (6<<16)|T_METADATA(17);
  ; i64 111 / i64 222 are opaque method values; i64 0 = should_reexecute.)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 3, i32 3, i64 10, i32 %x,
                 i64 393233, i64 111, i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %o,
                 i64 393233, i64 222, i64 0, i32 9, i32 9, i64 10, i32 %x) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %o is NeverEscapes: eliminated and described right AFTER THE ROOT SCOPE
; PREFIX (should_reexecute i64 0 + duplicated-BCI pair i32 3, i32 3):
; header (vo_id=0, ScalarValueType, T_OBJECT):
; (0<<32)|(4<<16)|12 = 262156; klass 100; field_count 1; field (offset 8,
; LocalType/T_INT): (8<<32)|10 = 34359738378 -> %x. The MIDDLE scope's
; locals slot becomes a VORefLocalType: (0<<32)|(8<<16)|12 = 524300,
; then i32 0.
; CHECK-LABEL: define void @multiscope_three(
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 3, i32 3, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 10, i32 %x, i64 393233, i64 111, i64 0, i32 5, i32 5, i64 524300, i32 0, i64 393233, i64 222, i64 0, i32 9, i32 9, i64 10, i32 %x) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
