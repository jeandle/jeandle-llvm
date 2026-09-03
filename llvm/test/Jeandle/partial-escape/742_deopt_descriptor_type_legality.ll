; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; These values are legal field-replay types, but HotSpot's deopt descriptor
; format has no BasicType for them.  Keep the original allocation and replay
; its fields before the safepoint instead of describing an invalid virtual
; object.  Ordinary non-deopt materialization remains covered by test 741.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @fixed_vector_falls_back_before_deopt(<4 x i32> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74201 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <4 x i32> %value, ptr addrspace(1) %slot, align 16
  call void @safepoint()
      [ "deopt"(i32 1, i32 1, i64 12, ptr addrspace(1) %obj) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @fixed_vector_falls_back_before_deopt(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic <4 x i32> %value, ptr addrspace(1) %pea.matslot unordered, align 16
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 1, i32 1, i64 12, ptr addrspace(1) %obj) ]

define void @i128_falls_back_before_deopt(i128 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74202 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store i128 %value, ptr addrspace(1) %slot, align 16
  call void @safepoint()
      [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %obj) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @i128_falls_back_before_deopt(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic i128 %value, ptr addrspace(1) %pea.matslot unordered, align 16
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %obj) ]

define void @half_falls_back_before_deopt(half %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74203 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store half %value, ptr addrspace(1) %slot, align 2
  call void @safepoint()
      [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %obj) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @half_falls_back_before_deopt(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic half %value, ptr addrspace(1) %pea.matslot unordered, align 2
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %obj) ]

!java-method-compilation = !{}
