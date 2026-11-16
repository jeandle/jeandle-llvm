; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/784_copy_fold_unwind_edge_dropped.cblog %s | FileCheck %s

; The copy invoke has its OWN unwind destination (u_copy), separate from the
; allocation's (u_alloc). Folding the copy must kill exactly its unwind edge:
; u_copy loses its only predecessor and is removed, while u_alloc survives —
; the destination escapes into a global AFTER the copy (PartiallyEscapes), so
; the allocation invoke stays live with its exception edge intact.

@sink = global ptr addrspace(1) null

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @copy_fold_unwind_edge(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u_alloc
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 4,
                            ptr null, ptr null, i64 4, i64 4)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read unwind label %u_copy
read:
  store ptr addrspace(1) %dest, ptr @sink
  ret i32 0
u_alloc:
  %lp1 = landingpad i64 cleanup
  br label %join
u_copy:
  %lp2 = landingpad i64 cleanup
  br label %join
join:
  %phi = phi i64 [ %lp1, %u_alloc ], [ %lp2, %u_copy ]
  resume i64 %phi
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; CHECK-LABEL: define i32 @copy_fold_unwind_edge
; The pseudo call is gone; the allocation survives (it escapes into the
; global after the copy) with its own landingpad, while the element loads
; read the real source at the call site.
; CHECK-NOT: jeandle.copy
; CHECK: jeandle.new_array
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; CHECK: landingpad i64
; CHECK-NEXT: cleanup
; CHECK: br label %join
; CHECK: resume i64
; CHECK-NOT: u_copy:

!java-method-compilation = !{}
