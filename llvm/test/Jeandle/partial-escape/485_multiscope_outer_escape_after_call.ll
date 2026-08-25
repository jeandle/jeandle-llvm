; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Multi-scope descriptors, outer-scope reference + escape AFTER the call: a
; VO referenced by the ROOT scope's locals is still VIRTUAL at the
; safepoint, but escapes LATER (stored to a global after the call), making
; it PartiallyEscapes. The multi-scope descriptor support applies to
; PartiallyEscapes VOs too: the VO is described in the ROOT scope's VO
; section and the outer-scope slot is rewritten to a VORef, while the
; OrigAlloc invoke is retained and the object is materialized at the later
; escape point.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

@glob = external global ptr addrspace(1)

define void @multiscope_escape_after(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %of = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %x, ptr addrspace(1) %of unordered, align 4
  ; Two-scope bundle: ROOT scope (bci 5, preceded by its should_reexecute
  ; i64) local 0 is %o; the INNERMOST scope
  ; (bci 9) has one i32 local. (i64 393233 = MethodType marker pair
  ; encoding: (6<<16)|T_METADATA(17).)
  call void @sink(i32 %x)
       [ "deopt"(i64 0, i32 5, i32 5, i64 12, ptr addrspace(1) %o,
                 i64 393233, i64 777,
                 i64 1, i32 9, i32 9, i64 10, i32 %x) ]
  ; %o escapes AFTER the safepoint.
  store ptr addrspace(1) %o, ptr @glob
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %o is PartiallyEscapes: the OrigAlloc invoke is RETAINED (materialized for
; the later escape), yet at the call it is still virtual — described right
; AFTER THE ROOT SCOPE PREFIX (should_reexecute i64 0 + duplicated-BCI pair
; i32 5, i32 5): header (vo_id=0, ScalarValueType,
; T_OBJECT): (0<<32)|(4<<16)|12 = 262156; klass 100; field_count 1; field
; (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> %x; the
; ROOT-scope slot becomes VORefLocalType: (0<<32)|(8<<16)|12 = 524300, then
; i32 0. The escaping @glob store survives.
; CHECK-LABEL: define void @multiscope_escape_after(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: call void @sink(i32 %x)
; CHECK-SAME: [ "deopt"(i64 0, i32 5, i32 5, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0,
; CHECK-SAME: i64 393233, i64 777,
; CHECK-SAME: i64 1, i32 9, i32 9, i64 10, i32 %x) ]
; CHECK: store ptr addrspace(1) %o, ptr @glob
; CHECK-NOT: poison

!java-method-compilation = !{}
