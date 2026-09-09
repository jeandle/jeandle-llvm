; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; LLVM volatile accesses are observable even when escape analysis proves that
; the referenced allocation is otherwise thread-local. The first volatile
; access therefore materializes the receiver, and both accesses survive with
; their original volatile semantics.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_volatile_no_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store volatile i32 7, ptr addrspace(1) %s, align 4
  %v = load volatile i32, ptr addrspace(1) %s, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_volatile_no_escape
; CHECK: @jeandle.new_instance
; CHECK-NOT: store volatile
; CHECK: store volatile i32 7
; CHECK-NOT: store volatile
; CHECK-NOT: load volatile
; CHECK: %[[V:[A-Za-z0-9._]+]] = load volatile i32
; CHECK-NOT: load volatile
; CHECK: call void @use(i32 %[[V]])
; CHECK: }

!java-method-compilation = !{}
