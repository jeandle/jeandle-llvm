; REQUIRES: asserts
; RUN: opt -disable-output -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:     -stats %s 2>&1 | FileCheck %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s \
; RUN:     | FileCheck %s --check-prefix=IR

; The -jeandle-pea-force-materialize-all knob is a hidden testing aid and
; must NOT be required to exercise the Regular convergence path. This test runs
; WITHOUT the flag: a loop with a loop-local, non-escaping allocation must
; converge in Regular mode and fully eliminate the allocation — proving the
; real Regular fixpoint is covered independently of the flag.
;
; Soundness/coverage assertion: the Regular -> MaterializeAll escalation
; counter must stay at ZERO (the loop genuinely converged in Regular mode and
; never fell back). -stats only prints counters with a non-zero value, so the
; escalation line must be ABSENT from the output.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_regular_converge(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr

hdr:
  %i = phi i32 [0, %entry], [%inext, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit

body:
  ; Loop-local allocation that never escapes: store a constant, read it back,
  ; consume the constant. No use of the pointer survives the iteration, so PEA
  ; virtualizes and eliminates it; the fixpoint converges in Regular mode.
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 1313 to ptr), i32 16, i1 false)
       to label %b unwind label %u
b:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 99, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  call void @sink_i32(i32 %v)
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

; The Regular fixpoint converged: the allocation is eliminated and the load
; folded to the stored constant 99.
; CHECK-DAG: partial-escape-analysis - Number of allocations eliminated (erased) by PEA
; The escalation counter must be ZERO (absent from -stats), i.e. Regular mode
; converged without falling back to MATERIALIZE_ALL.
; CHECK-NOT: Regular -> MaterializeAll mode flips

; IR-LABEL: define void @test_regular_converge
; The alloc is gone and the load folded to the constant.
; IR-NOT: @jeandle.new_instance
; IR-NOT: load atomic i32
; IR: call void @sink_i32(i32 99)

!java-method-compilation = !{}
