; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; When a Case-C candidate PHI has a self-reference among its
; incomings (the back-edge feeds the PHI back into itself), the
; synthesize-Case-C path early-bails. The fallback is Case-A: every
; virtual incoming materialised at its pred terminator. The lone
; (non-back-edge) virtual incoming gets materialised; the back-edge
; PHI-self incoming stays untouched.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_caseC_self_loop(i32 %n)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %loop unwind label %u
loop:
  %p = phi ptr addrspace(1) [ %o, %entry ], [ %p, %body ]
  %i = phi i32 [ 0, %entry ], [ %i1, %body ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  call void @sink(ptr addrspace(1) %p)
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The Case-C synthesis self-reference bail forces Case-A: %o is
; materialised at entry (so the PHI's forward-edge incoming becomes the
; materialised invoke). The alloc itself survives in IR (it IS the
; materialised pointer for the forward arm).
; CHECK-LABEL: define void @test_caseC_self_loop
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)

!java-method-compilation = !{}
