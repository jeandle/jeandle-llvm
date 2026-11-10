; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/793_clone_array_fold_concrete.cblog %s | FileCheck %s

; Malformed negative payload offsets must conservatively retain the clone.
@arrayOopDesc.length_offset_in_bytes = constant i64 12

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @clone_array_negative_offset(ptr addrspace(1) "java-klass"="12345" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 3, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_clone unwind label %u
do_clone:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 -8, ptr addrspace(1) %dst, i64 -8,
                          i64 5, ptr null, ptr null, i64 32, i64 32)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
  br label %read
read:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dst, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %db, i64 0
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  ret i32 %v0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }
; CHECK-LABEL: define i32 @clone_array_negative_offset
; CHECK: @jeandle.new_array
; CHECK: call void @jeandle.copy
; CHECK-SAME: i64 -8, ptr addrspace(1) %dst, i64 -8, i64 5
; CHECK: load atomic i32
!java-method-compilation = !{}
