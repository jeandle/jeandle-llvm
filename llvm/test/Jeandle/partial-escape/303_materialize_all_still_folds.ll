; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-force-materialize-all=true %s | FileCheck %s

; MATERIALIZE_ALL preserves intra-block folds. The
; -jeandle-pea-force-materialize-all=true testing knob forces every
; top-level processLoop into MaterializeAll, so the deferred-end-of-block
; Materialize emission path is exercised deterministically.
;
; Body: alloc + store(7) + load. With "virtualize-then-materialise",
; the alloc is registered (intra-block FieldStates are populated), the
; load against the same slot folds against FieldStates to the constant
; 7, and @sink_i32 is called with that constant. The end-of-block
; deferred Materialize retains OrigAlloc and replays the final field state;
; it does not emit a new allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_mat_all_folds(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr

hdr:
  %i = phi i32 [0, %entry], [%inext, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit

body:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                  ptr inttoptr (i64 7777 to ptr), i32 16, i1 false)
              to label %b unwind label %u
b:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 7, ptr addrspace(1) %slot unordered, align 4
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

; CHECK-LABEL: define void @test_mat_all_folds
; OrigAlloc remains the sole allocation.
; CHECK: %obj = invoke {{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; The intra-block load folded to the constant 7 against FieldStates.
; CHECK-NOT: load atomic i32
; CHECK: call void @sink_i32(i32 7)

!java-method-compilation = !{}
