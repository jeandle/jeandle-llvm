; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; freeze on a virtual pointer is a pointer-identity-preserving passthrough
; — propagatePointerAlias forwards the virtual alias. A load through the
; frozen alias resolves against the original virtual's field state. Alloc is
; eliminated; the load folds to the stored constant 42.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_freeze_passthrough() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %s unordered, align 4
  %f = freeze ptr addrspace(1) %s
  %v = load atomic i32, ptr addrspace(1) %f unordered, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_freeze_passthrough
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 42)

!java-method-compilation = !{}
