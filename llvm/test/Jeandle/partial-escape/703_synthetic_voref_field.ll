; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=IR

; A Case-C synthetic VO whose field holds ANOTHER virtual object (the same
; %inner stored into both branches, so AllSame across preds) is DESCRIBED with a
; VORef FIELD pointing at %inner's descriptor. %inner is reached only
; transitively (not a direct bundle operand), so the transitive descriptor
; closure must describe it. Mirrors nested virtual-object descriptors + id back-ref.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()

define void @synthetic_with_inner_field(i1 %c) gc "hotspotgc" {
entry:
  %inner = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70302 to ptr), i32 16, i1 false) [ "deopt"(i32 703001) ]
  %innerf = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  store atomic i32 77, ptr addrspace(1) %innerf unordered, align 4
  br i1 %c, label %left, label %right
left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70301 to ptr), i32 24, i1 false) [ "deopt"(i32 703011) ]
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %af unordered, align 8
  br label %merge
right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 70301 to ptr), i32 24, i1 false) [ "deopt"(i32 703012) ]
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %bf unordered, align 8
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %p) ]
  ret void
}

; IR-LABEL: define void @synthetic_with_inner_field(
; All three allocations eliminated; no replay.
; IR-NOT: call {{.*}}@jeandle.new_instance
; IR-NOT: store atomic
; IR: call void @safepoint() [ "deopt"(
; IR-SAME: i32 99, i32 99,
; Root-first dense numbering assigns synthetic %p wire id 0. Its offset-8
; field is a VORef to the transitively discovered %inner at wire id 1.
; IR-SAME: i64 262156, i64 70301, i32 1,
; IR-SAME: i64 34360262668, i32 1,
; %inner descriptor (wire id 1): klass 70302, field_count 1, offset 8 = 77.
; IR-SAME: i64 4295229452, i64 70302, i32 1,
; IR-SAME: i64 34359738378, i32 77,
; %p slot -> VORef wire id 0.
; IR-SAME: i64 524300, i32 0) ]
; IR-NOT: poison

!java-method-compilation = !{}
