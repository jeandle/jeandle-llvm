; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: an LLVM PHI of ptr addrspace(1) mixes a virtual incoming (the
; allocation in branch %left) with a non-virtual incoming (a function-arg
; pointer in branch %right). The analyzer materializes the virtual incoming
; at its predecessor; the LLVM PHI itself stays in IR with the materialized
; pointer on the left edge and the original arg pointer on the right edge.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_phi_mixed(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %lcont unwind label %u
lcont:
  br label %merge
right:
  br label %merge
merge:
  %m = phi ptr addrspace(1) [ %o, %lcont ], [ %p, %right ]
  call void @sink(ptr addrspace(1) %m)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_phi_mixed
; CHECK: invoke {{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)
; CHECK: call void @sink

!java-method-compilation = !{}
