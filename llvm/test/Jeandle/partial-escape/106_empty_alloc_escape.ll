; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Edge case: virtual with zero stores between alloc and escape.
; Materialization with zero FieldEntries changes only analysis state: the
; original allocation is retained and no replay IR is required.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_empty_alloc_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @sink(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; OrigAlloc is the only invoke and @sink consumes it directly.
; CHECK-LABEL: define void @test_empty_alloc_escape
; CHECK: %[[ORIG:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK: call void @sink(ptr addrspace(1) %[[ORIG]])

!java-method-compilation = !{}
