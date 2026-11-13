; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/795_copy_fold_packed_source.cblog -jeandle-dump-pea-stats %s 2>%t.stats | FileCheck %s
; RUN: FileCheck %s --check-prefix=STATS < %t.stats

; Packed writes must not be interpreted as independent Java array elements.
; Disjoint packed writes do not affect default elements in the copy window.

target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; STATS: PEA stats @inside_packed: {{.*}}CopyFolds=0
; CHECK-LABEL: define i8 @inside_packed(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 8721
; CHECK: invoke void @jeandle.copy
; CHECK: load atomic i8
; CHECK: ret i8 %v
define i8 @inside_packed() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 1, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @first_packed_byte: {{.*}}CopyFolds=0
; CHECK-LABEL: define i8 @first_packed_byte(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 8721
; CHECK: invoke void @jeandle.copy
; CHECK: load atomic i8
; CHECK: ret i8 %v
define i8 @first_packed_byte() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @whole_packed: {{.*}}CopyFolds=1
; CHECK-LABEL: define i8 @whole_packed(
; CHECK-NOT: @jeandle.copy
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 8721
; CHECK: load atomic i8
; CHECK: ret i8 %v
define i8 @whole_packed() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @later_packed: {{.*}}CopyFolds=0
; CHECK-LABEL: define i8 @later_packed(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 17
; CHECK-NEXT: store atomic i8 17, {{.*}} align 1
; CHECK: getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
; CHECK-NEXT: store atomic i8 34, {{.*}} align 1
; CHECK: invoke void @jeandle.copy
; CHECK: load atomic i8
; CHECK: ret i8 %v
define i8 @later_packed() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 17
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @packed_after_window: {{.*}}CopyFolds=1
; CHECK-LABEL: define i8 @packed_after_window(
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: @jeandle.new_array
; CHECK: ret i8 0
define i8 @packed_after_window() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 18
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @packed_before_window: {{.*}}CopyFolds=1
; CHECK-LABEL: define i8 @packed_before_window(
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: @jeandle.new_array
; CHECK: ret i8 0
define i8 @packed_before_window() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 2, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @clone_packed: {{.*}}CopyFolds=1
; CHECK-LABEL: define i8 @clone_packed(
; CHECK-NOT: @jeandle.copy
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 8721
; CHECK: load atomic i8
; CHECK: ret i8 %v
define i8 @clone_packed() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic i16 8721, ptr addrspace(1) %sp unordered, align 1
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 12, ptr addrspace(1) %dst, i64 12, i64 2, ptr null, ptr null, i64 4, i64 4)
      #1 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STATS: PEA stats @different_physical_type: {{.*}}CopyFolds=1
; CHECK-LABEL: define i32 @different_physical_type(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: bitcast float 1.000000e+00 to i32
; CHECK: ret i32
define i32 @different_physical_type() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12346 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12346 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
      to label %init unwind label %u
init:
  %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
  store atomic float 1.000000e+00, ptr addrspace(1) %sp unordered, align 4
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 4, i64 4)
      #0 to label %read unwind label %u
read:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i32, ptr addrspace(1) %dp unordered, align 1
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
attributes #1 = { "jeandle.copy.kind"="clone-array" }
!java-method-compilation = !{}
