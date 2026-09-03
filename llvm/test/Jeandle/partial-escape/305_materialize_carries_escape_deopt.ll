; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; An escaping VO keeps its original allocation: OrigAlloc is KEPT and
; dominates every use, so the escape sink's "deopt" bundle (which carries
; only constant values here, no OrigAlloc reference) is preserved as-is,
; and the sink receives OrigAlloc directly.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @escape_with_bundle() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ; No "deopt" bundle on the allocation itself.
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; Rich "deopt" bundle on the sink — preserved verbatim (OrigAlloc kept).
  call void @sink(ptr addrspace(1) %o) [ "deopt"(i32 42) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @escape_with_bundle
; The original allocation invoke is RETAINED as the sole allocation.
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr {{.*}}, i32 16, i1 false)
; CHECK-NOT: = invoke hotspotcc{{.*}}@jeandle.new_instance
; The sink receives OrigAlloc and keeps its deopt bundle.
; CHECK: call void @sink(ptr addrspace(1) %o) [ "deopt"(i32 42) ]

!java-method-compilation = !{}
