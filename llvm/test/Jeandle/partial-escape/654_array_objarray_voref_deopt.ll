; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/654_array_objarray_voref_deopt.cblog %s | FileCheck %s

; Array VO deopt descriptor (Point[]). A never-escaping object array of length
; 2. Element 0 holds ANOTHER in-scope virtual VO (a Point instance, %point) —
; emitted as a VORef FIELD by vo-id (transitive closure through an array
; element). Element 1 is untouched (default null). The Point instance is
; referenced ONLY via arr[0] (transitive), so it must get its own instance
; descriptor (T_OBJECT header) AND its field described, exactly like the
; instance VORef-field case (643) but reached via an array element. This
; pins: (a) the transitive closure traverses array VORef elements, and (b) a
; mix of array descriptor (T_ARRAY) + instance descriptor (T_OBJECT) is emitted
; in the same VO section.

@arrayOopDesc.element_size.object = private constant i32 8

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @array_objarray_voref_deopt(i32 %val) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  ; Allocate arr first (vo-id 0, root — it is the bundle operand).
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 54004 to ptr), i32 2, i32 32, i32 16, i32 1048576)
         to label %alloc_point unwind label %u
alloc_point:
  ; point is vo-id 1, transitive (referenced ONLY via arr[0]).
  %point = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 54005 to ptr), i32 16, i1 false)
         to label %body unwind label %u
body:
  ; point: offset 8 = int %val.
  %pf = getelementptr inbounds i8, ptr addrspace(1) %point, i64 8
  store atomic i32 %val, ptr addrspace(1) %pf unordered, align 4
  ; arr[0] = %point (a VORef element). objArray base 16, scale 8: index 0 @ 16.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %e0 = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 0
  store atomic ptr addrspace(1) %point, ptr addrspace(1) %e0 unordered, align 8
  ; Use point's field value so it is not dead.
  %pv = load atomic i32, ptr addrspace(1) %pf unordered, align 4
  ; %arr lives ONLY in the deopt bundle; %point lives ONLY via arr[0].
  call void @sink(i32 %pv)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %arr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_objarray_voref_deopt
; Both OrigAllocs are eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %val)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; Root-first dense numbering assigns arr wire id 0 and the transitively
; discovered point wire id 1. The arr descriptor is emitted first.
; arr descriptor header (wire id 0, ScalarValueType, T_ARRAY=13): 262157
; CHECK-SAME: i64 262157, i64 54004, i32 2,
; arr elem 0 @ offset 16 (VORef to point wire id 1):
;   (16<<32)|(8<<16)|12 = 68720001036
; CHECK-SAME: i64 68720001036, i32 1,
; arr elem 1 @ offset 24 (untouched default null), LocalType/T_OBJECT:
;   (24<<32)|12 = 103079215116
; CHECK-SAME: i64 103079215116, ptr addrspace(1) null,
; point descriptor header (wire id 1, ScalarValueType, T_OBJECT):
;   (1<<32)|(4<<16)|12 = 4295229452
; CHECK-SAME: i64 4295229452, i64 54005, i32 1,
; point field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> %val
; CHECK-SAME: i64 34359738378, i32 %val,
; the OrigAlloc locals slot -> VORefLocalType (wire id 0): 524300
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: addrspace(1) %arr
; CHECK-NOT: addrspace(1) %point

!java-method-compilation = !{}
