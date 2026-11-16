; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/785_copy_fold_zero_length.cblog %s | FileCheck %s

; Empty copies still require a source bounds proof, including on unwind paths.
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define i32 @unknown_length(ptr addrspace(1) "java-klass"="12345" %src, i64 %length) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 5, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 %length, i64 2) #0
      to label %read unwind label %unwind
read:
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @unknown_length(
; CHECK: invoke void @jeandle.copy
; CHECK-SAME: i64 0, i64 0,
; CHECK: to label %read unwind label %unwind
; CHECK: load atomic i32
; CHECK: resume i64

define i32 @out_of_bounds(ptr addrspace(1) "java-klass"="12345" %src, i64 %length) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 5, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 3, i64 2) #0
      to label %read unwind label %unwind
read:
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @out_of_bounds(
; CHECK: invoke void @jeandle.copy
; CHECK-SAME: i64 0, i64 0,
; CHECK: to label %read unwind label %unwind
; CHECK: load atomic i32
; CHECK: resume i64

define i32 @at_end(ptr addrspace(1) "java-klass"="12345" %src, i64 %length) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 3, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 3, i64 2) #0
      to label %read unwind label %unwind
read:
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @at_end(
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: load atomic
; CHECK: ret i32 0

define i32 @validated(ptr addrspace(1) "java-klass"="12345" %src, i64 %length) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 3, ptr addrspace(1) %dst, i64 0, i64 0, ptr null, ptr null, i64 %length, i64 2) #1
      to label %read unwind label %unwind
read:
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @validated(
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: load atomic
; CHECK: ret i32 0

attributes #0 = { "jeandle.copy.kind"="arraycopy" }
attributes #1 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
