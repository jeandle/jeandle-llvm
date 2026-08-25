; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; 2-stage MATERIALIZE_ALL escalation. A loop body whose stores
; reference an unknown global pointer mid-loop creates a state-split that
; the regular fixpoint cannot collapse. After the iter cap, the analyzer
; falls back to MATERIALIZE_ALL, runs one body pass, re-checks
; convergence, and if non-equivalent, retries one more pass (the second
; stage). The function must compile cleanly and leave the alloc in IR
; (materialised by the MATERIALIZE_ALL path).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

@G = external addrspace(1) global ptr addrspace(1)

define void @test_two_stage(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr

hdr:
  %i = phi i32 [0, %entry], [%inext, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit

body:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
           to label %b unwind label %u
b:
  ; Force the alloc to escape via a global store every iter (cannot fold).
  store ptr addrspace(1) %a, ptr addrspace(1) @G
  br label %latch
latch:
  %inext = add i32 %i, 1
  br label %hdr

exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The alloc and the escape both survive in IR; the function compiles cleanly.
; CHECK-LABEL: define void @test_two_stage
; CHECK: invoke {{.*}}@jeandle.new_instance({{.*}}i64 5555
; CHECK: store ptr addrspace(1)

!java-method-compilation = !{}
