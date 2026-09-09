; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 \
; RUN:   -jeandle-dump-pea-ir-function=test_two_round_elim %s 2>&1 \
; RUN:   | grep '^;; PEA-' | FileCheck %s --check-prefix=CAP2
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 %s \
; RUN:   | FileCheck %s --check-prefix=FINAL

; Outer fixpoint demonstration. The escape arm (%escape -> sink) is
; guarded by an `icmp ne` of a load from a constant-zero global; the analyzer
; in iteration 0 cannot see through the load and therefore leaves the partial
; escape unchanged. Inter-round canonicalization folds the condition and
; removes the dead escape arm. Iteration 1 then virtualizes the allocation and
; folds its field load to 42.
;
; A cap of two is sufficient for the final transformation, but not for an
; additional idle confirmation round. This test pins both that marker sequence
; and the final function shape.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_two_round_elim()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; This load+icmp folds to `false` only after InstCombine; PEA in round 1
  ; cannot see through it.
  %v = load i32, ptr @G_zero, align 4
  %c = icmp ne i32 %v, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CAP2: ;; PEA-DUMP before iter=0 function test_two_round_elim
; CAP2-NEXT: ;; PEA-DUMP after iter=0 function test_two_round_elim transform_idle=1
; CAP2-NEXT: ;; PEA-DUMP before iter=1 function test_two_round_elim
; CAP2-NEXT: ;; PEA-DUMP after iter=1 function test_two_round_elim transform_idle=0
; CAP2-NEXT: ;; PEA-SUMMARY function test_two_round_elim rounds=2 stop=iteration-cap
; CAP2-NOT: ;; PEA-

; FINAL-LABEL: define i32 @test_two_round_elim()
; FINAL-NOT: jeandle.new_instance
; FINAL-NOT: call void @sink
; FINAL-NOT: store
; FINAL-NOT: load
; FINAL-NOT: phi
; FINAL-NOT: poison
; FINAL: ret i32 42
; FINAL-NEXT: }

!java-method-compilation = !{}
