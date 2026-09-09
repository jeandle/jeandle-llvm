; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 %s | FileCheck %s

; Outer convergence follows actual work rather than allocation-count
; heuristics. A round that changes either the PEA transform or the complete
; canonicalized Function IR must be followed by another PEA round when the cap
; permits.
;
; This test exercises a chain of three nested allocs whose virtualisation
; opportunities only fully resolve after multiple rounds of analyse +
; canonicalise. The outer loop therefore reaches the later round that
; completes the virtualisation.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_delta_convergence()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 16, i1 false)
       to label %a2 unwind label %u
a2:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 16, i1 false)
       to label %a3 unwind label %u
a3:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 33333 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %v = load i32, ptr @G_zero, align 4
  %cc = icmp ne i32 %v, 0
  br i1 %cc, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %a)
  call void @sink(ptr addrspace(1) %b)
  call void @sink(ptr addrspace(1) %c)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %c, i64 8
  store atomic i32 21, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; All three allocations virtualised after the iterative fixpoint. The
; final function reduces to ret i32 21.
; CHECK-LABEL: define i32 @test_delta_convergence()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: call void @sink
; CHECK: ret i32 21

!java-method-compilation = !{}
