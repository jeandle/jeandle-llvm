; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Self-loop where the header allocation escapes in the body before the
; back-edge. PartiallyEscapes retains the original %o invoke; both the escape
; and any loop-carried identity use the same dominating receiver. No per-edge
; allocation or materialized-object PHI is needed, and no poison may enter a
; loop PHI or store.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @selfloop_perpred(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %header
header:
  %i = phi i32 [ 0, %entry ], [ %i.next, %body ]
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %body unwind label %u
body:
  call void @sink(ptr addrspace(1) %o)
  %i.next = add i32 %i, 1
  %c = icmp slt i32 %i.next, %n
  br i1 %c, label %header, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; OrigAlloc %o is the only allocation and is passed directly to @sink.
; CHECK-LABEL: define void @selfloop_perpred
; CHECK: %o = invoke {{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-NOT: phi {{.*}}poison
; CHECK-NOT: store{{.*}}poison

!java-method-compilation = !{}
