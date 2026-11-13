; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/792_clone_array_fold_v2v.cblog %s | FileCheck %s

; clone-array byte-payload fold, virtual-to-virtual: int[3] (data end 28,
; inside a word-rounded payload window that still covers every element).
; This module pins the length offset to 12 so the window starts BELOW the
; first element — a more aggressive sub-element edge than the frontend's
; own base — proving the coverage check ignores header bytes in the window.

@arrayOopDesc.length_offset_in_bytes = constant i64 12

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @clone_array_fold_v2v() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 3, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %stores unwind label %u
stores:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 0
  %s2 = getelementptr inbounds i32, ptr addrspace(1) %sb, i64 2
  store atomic i32 31, ptr addrspace(1) %s0 unordered, align 4
  store atomic i32 33, ptr addrspace(1) %s2 unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 3, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %stale unwind label %u
stale:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dst, i32 16
  %d1 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 1
  store atomic i32 99, ptr addrspace(1) %d1 unordered, align 4
  br label %do_clone
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 12, ptr addrspace(1) %dst, i64 12,
                          i64 3, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %v0 = load atomic i32, ptr addrspace(1) %s0 unordered, align 4
  %v1 = load atomic i32, ptr addrspace(1) %d1 unordered, align 4
  %v2 = load atomic i32, ptr addrspace(1) %s2 unordered, align 4
  %a1 = add i32 %v0, %v1
  %r = add i32 %a1, %v2
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }

; CHECK-LABEL: define i32 @clone_array_fold_v2v
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.copy
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; v0/v2 read the SOURCE after the clone (same values); the stale 99 in the
; destination element 1 is erased to the source's default 0.
; CHECK: %a1 = add i32 31, 0
; CHECK: %r = add i32 %a1, 33
; CHECK: ret i32 %r

!java-method-compilation = !{}
