; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Recognised non-escaping LLVM intrinsics: llvm.assume should be
; treated as a no-op for escape analysis. Even when the assume's "align"
; operand bundle references the virtual pointer, the alloc must remain
; eliminable. Per the plan, an assume on a virtual must NOT escalate to
; materialization.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @llvm.assume(i1)
declare i32 @__gxx_personality_v0(...)

define void @test_assume_noop() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call void @llvm.assume(i1 true) [ "align"(ptr addrspace(1) %o, i64 8) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_assume_noop
; CHECK-NOT: jeandle.new_instance
; CHECK: ret void

!java-method-compilation = !{}
