; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/772_arraycopy_fold_overlap.cblog %s | FileCheck %s

; src == dest with overlapping ranges (arraycopy(a, 0, a, 1, 2)) must fold
; with memmove semantics: the source cells are snapshotted before any
; destination cell is written, so a[1] receives the ORIGINAL a[0] and a[2]
; receives the ORIGINAL a[1]. Preexisting destination values are fully
; overwritten by the copy.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare i32 @__gxx_personality_v0(...)

define i32 @test_arraycopy_fold_overlap() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %a, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  %p2 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 2
  store atomic i32 1, ptr addrspace(1) %p0 unordered, align 4
  store atomic i32 2, ptr addrspace(1) %p1 unordered, align 4
  store atomic i32 3, ptr addrspace(1) %p2 unordered, align 4
  ; arraycopy(a, 0, a, 1, 2): a becomes [1, 1, 2, 0].
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %a, i64 0, ptr addrspace(1) %a, i64 1, i64 2,
            ptr null, ptr null, i64 4, i64 4)
         to label %ac unwind label %u
ac:
  %v1 = load atomic i32, ptr addrspace(1) %p1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %p2 unordered, align 4
  %r = add i32 %v1, %v2
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; CHECK-LABEL: define i32 @test_arraycopy_fold_overlap
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraycopy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: %r = add i32 1, 2
; CHECK: ret i32 %r

!java-method-compilation = !{}
