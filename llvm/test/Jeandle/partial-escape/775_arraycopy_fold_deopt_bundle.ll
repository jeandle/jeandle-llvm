; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/775_arraycopy_fold_deopt_bundle.cblog %s | FileCheck %s

; The frontend's arraycopy pseudo call is an INVOKE carrying a deopt operand
; bundle (its callsite attributes request an exception edge and GC state).
; Folding must tolerate the bundle: the call — and with it the bundle and the
; unwind edge — is deleted, and the bundle rewrite no-ops at apply. A
; destination that later escapes materializes with the copied value replayed
; (scalar form), exercising the full fold-then-escape pipeline.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_arraycopy_fold_deopt_bundle() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u
n1:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12346 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n2 unwind label %u
n2:
  %sbase = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sbase, i64 0
  store atomic i32 42, ptr addrspace(1) %s0 unordered, align 4
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 1,
            ptr null, ptr null, i64 4, i64 4) #0 [ "deopt"(i32 42) ]
         to label %ac unwind label %u
ac:
  call void @sink(ptr addrspace(1) %dest)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; CHECK-LABEL: define void @test_arraycopy_fold_deopt_bundle
; The pseudo call (with its deopt bundle and unwind edge) is folded away.
; CHECK-NOT: jeandle.arraycopy
; CHECK-NOT: landingpad
; The source array is eliminated; only the destination survives, and the
; copied element is replayed as a real store before the escape.
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i32 42
; CHECK: call void @sink

!java-method-compilation = !{}
