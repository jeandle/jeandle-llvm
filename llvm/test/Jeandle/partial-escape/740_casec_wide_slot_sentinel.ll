; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i16 @casec_wide_slot_sentinel(i1 %c) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74001 to ptr), i32 16, i1 false)
      to label %ls unwind label %unwind
ls:
  %lf = getelementptr i8, ptr addrspace(1) %o1, i64 9223372036854775805
  store atomic i8 1, ptr addrspace(1) %lf unordered, align 1
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74001 to ptr), i32 16, i1 false)
      to label %rs unwind label %unwind
rs:
  %rf = getelementptr i8, ptr addrspace(1) %o2, i64 9223372036854775805
  store atomic i16 2, ptr addrspace(1) %rf unordered, align 1
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %o1, %ls ], [ %o2, %rs ]
  %f = getelementptr i8, ptr addrspace(1) %p, i64 9223372036854775805
  %v = load atomic i16, ptr addrspace(1) %f unordered, align 1
  ret i16 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i16 @casec_wide_slot_sentinel(
; CHECK: @jeandle.new_instance
; CHECK: store atomic i8 1
; CHECK: @jeandle.new_instance
; CHECK: store atomic i16 2
; CHECK: load atomic i16

!java-method-compilation = !{}
