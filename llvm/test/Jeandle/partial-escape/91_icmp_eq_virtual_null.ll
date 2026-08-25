; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; icmp eq virtual, null should fold to false (a virtual is by construction
; non-null since it tracks an in-flight allocation). This is a
; recognised JavaOp-style fold; the analyzer should constant-fold the icmp,
; the conditional branch becomes unconditional, and the alloc is eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_null() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %is_null = icmp eq ptr addrspace(1) %o, null
  br i1 %is_null, label %dead, label %live
dead:
  call void @use(i32 -1)
  ret void
live:
  call void @use(i32 1)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc is eliminated. The conditional branch's "dead" arm (where %o is
; null) is unreachable.
; CHECK-LABEL: define void @test_icmp_eq_null
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call void @use(i32 -1)
; CHECK: call void @use(i32 1)

!java-method-compilation = !{}
