; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VO referenced ONLY by another allocation invoke's deopt bundle. Allocation
; invokes go through
; recordDeoptBundleMappings like every other safepoint: %a (still virtual at
; %b's allocation) is described in %b's bundle, exactly as virtual objects
; are described in an allocation's frame state. Regression guard: skipping
; the bundle scan at an allocation would leave %a's only use to be
; poison-RAUW'd inside %b's surviving bundle (the end-to-end
; fill_one_scope_value ShouldNotReachHere).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @vo_in_other_alloc_bundle(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 16, i1 false)
       to label %n1 unwind label %u
n1:
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 %x, ptr addrspace(1) %af unordered, align 4
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a) ]
       to label %n2 unwind label %u
n2:
  call void @sink(ptr addrspace(1) %b)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; %a is NeverEscapes (only in %b's bundle): eliminated and described. %b is
; PartiallyEscapes (sink(%b)): its invoke is RETAINED with the descriptor.
; Descriptor %a (vo_id=0, ScalarValueType, T_OBJECT): (0<<32)|(4<<16)|12 =
; 262156; field (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> %x;
; %a's slot becomes VORefLocalType: (0<<32)|(8<<16)|12 = 524300, then i32 0.
; CHECK-LABEL: define void @vo_in_other_alloc_bundle(
; CHECK-NOT: %a = invoke
; CHECK: %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 262156, i64 100, i32 1, i64 34359738378, i32 %x, i64 524300, i32 0) ]
; CHECK: call void @sink(ptr addrspace(1) %b)
; CHECK-NOT: poison

!java-method-compilation = !{}
