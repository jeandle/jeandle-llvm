; RUN: opt -S --jeandle -jeandle-vm-callback-log=%S/Inputs/pre-pea-high-tier-e2e.cblog %s | FileCheck %s

; End-to-end for the motivating example:
;   int[] array = new int[10];
;   for (int i = 0; i < array.length; i++) { array[i] = 0; }
;   return array[3];
;
; JavaOpLengthFolding folds both jeandle.arraylength calls to 10, making the
; trip count constant; the pre-PEA full unroll straight-lines the loop into
; constant-offset stores (and the constant-folded bounds checks die); PEA
; then virtualizes the whole array and folds the final load to 0.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)

declare i32 @__gxx_personality_v0(...)

; Minimal barrier scaffolding required by InsertGCBarriers (mirrors
; lately-use-cross-default-opt.ll): the pass asserts these JavaOps exist,
; even though this test inserts no reference-store barriers.
@llvm.used = appending global [2 x ptr] [ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier], section "llvm.metadata"

define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #0 {
entry:
  ret void
}

define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #0 {
entry:
  ret void
}

attributes #0 = { noinline "lower-phase"="2" }

define i32 @test_array_init() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 10, i32 56, i32 16, i32 1048576)
         to label %preheader unwind label %u
preheader:
  br label %loop
loop:
  %i = phi i32 [ 0, %preheader ], [ %inc, %store ]
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  %cmp = icmp ult i32 %i, %len
  br i1 %cmp, label %check, label %exit
check:
  ; The bounds-check form the frontend emits per array access: a second
  ; jeandle.arraylength call compared against the index.
  %len2 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  %oob = icmp uge i32 %i, %len2
  br i1 %oob, label %fail, label %store
fail:
  unreachable
store:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %addr = getelementptr inbounds i32, ptr addrspace(1) %base, i32 %i
  store atomic i32 0, ptr addrspace(1) %addr unordered, align 4
  %inc = add nuw i32 %i, 1
  br label %loop
exit:
  %base2 = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %addr3 = getelementptr inbounds i32, ptr addrspace(1) %base2, i32 3
  %v = load atomic i32, ptr addrspace(1) %addr3 unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define {{.*}}@test_array_init
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK: ret i32 0

!java-method-compilation = !{}
!static-call-patch-size = !{!0}

!0 = !{i32 5}
