; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/771_arraycopy_fold_int.cblog %s | FileCheck %s

; System.arraycopy (validated, constant offsets and length) between two
; virtual int[] arrays folds into PEA field state: the tracked source cells
; propagate to the destination, the untracked source element contributes the
; Java default (zero), the pseudo call is deleted together with its unwind
; edge, and neither array escapes. Downstream loads of the destination fold
; to the copied values.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare i32 @__gxx_personality_v0(...)

define i32 @test_arraycopy_fold_int() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %s1 = getelementptr inbounds i32, ptr addrspace(1) %sbase, i64 1
  store atomic i32 100, ptr addrspace(1) %s0 unordered, align 4
  store atomic i32 200, ptr addrspace(1) %s1 unordered, align 4
  ; arraycopy(src, 0, dest, 0, 3): copies 100, 200 and the default 0.
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 3,
            ptr null, ptr null, i64 4, i64 4)
         to label %ac unwind label %u
ac:
  %dbase = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %dbase, i64 0
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %dbase, i64 1
  %d2 = getelementptr inbounds i32, ptr addrspace(1) %dbase, i64 2
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %d2 unordered, align 4
  %r1 = add i32 %v0, %v1
  %r2 = add i32 %r1, %v2
  ret i32 %r2
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; CHECK-LABEL: define i32 @test_arraycopy_fold_int
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraycopy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %r1 = add i32 100, 200
; CHECK: %r2 = add i32 %r1, 0
; CHECK: ret i32 %r2

!java-method-compilation = !{}
