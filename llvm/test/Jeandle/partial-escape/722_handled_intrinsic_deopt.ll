; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; llvm.sideeffect is otherwise a handled, non-escaping intrinsic, but its
; deopt bundle is executable frame state.  The virtual root must be described
; before the intrinsic handler returns.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @llvm.sideeffect()
declare ptr addrspace(1)
    @llvm.launder.invariant.group.p1(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @handled_intrinsic_deopt()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72201 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  call void @llvm.sideeffect()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_deopt()
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 72201, i32 0,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: poison

define void @handled_intrinsic_nested_deopt(i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72202 to ptr), i32 24, i1 false)
      to label %alloc.inner unwind label %unwind

alloc.inner:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72203 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %inner.field = getelementptr inbounds i8, ptr addrspace(1) %inner, i64 8
  %outer.field = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  store atomic i32 %value, ptr addrspace(1) %inner.field unordered, align 4
  store atomic ptr addrspace(1) %inner,
      ptr addrspace(1) %outer.field unordered, align 8
  call void @llvm.sideeffect()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %outer) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_nested_deopt(
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @llvm.sideeffect()
; The transitive inner descriptor and the root outer descriptor must both be
; present at this same intrinsic safepoint. Root-first dense numbering assigns
; outer wire id 0 and inner wire id 1.
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 72202, i32 1,
; CHECK-SAME: i64 68720001036, i32 1,
; CHECK-SAME: i64 4295229452, i64 72203, i32 1,
; CHECK-SAME: i64 34359738378, i32 %value,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: poison

define void @handled_intrinsic_synthetic_deopt(i1 %pick)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %pick, label %left, label %right

left:
  %left.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72204 to ptr), i32 16, i1 false)
      to label %merge unwind label %unwind

right:
  %right.object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72204 to ptr), i32 16, i1 false)
      to label %merge unwind label %unwind

merge:
  %object = phi ptr addrspace(1)
      [ %left.object, %left ], [ %right.object, %right ]
  call void @llvm.sideeffect()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %object) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_synthetic_deopt(
; CHECK-NOT: jeandle.new_instance
; The synthetic root is described as dense wire id 0 at the sideeffect
; safepoint.
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 72204, i32 0,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NOT: poison

define void @handled_intrinsic_derived_deopt()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72205 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind

body:
  %derived = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  call void @llvm.sideeffect()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %derived) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_derived_deopt()
; A derived root cannot be described, so the original allocation remains real.
; CHECK: %[[O:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[DERIVED:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[O]], i64 8
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: ptr addrspace(1) %[[DERIVED]]
; CHECK-NOT: poison

define void @handled_intrinsic_informational_bundle()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72206 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  call void @llvm.sideeffect() [ "informational"(ptr addrspace(1) %o) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_informational_bundle()
; Informational bundles remain non-escaping and may observe poison after the
; otherwise-unused allocation is eliminated.
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: [ "informational"(ptr addrspace(1) poison) ]

define void @handled_intrinsic_ordinary_operand()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72207 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %alias = call ptr addrspace(1)
      @llvm.launder.invariant.group.p1(ptr addrspace(1) %o)
  call void @llvm.sideeffect()
      [ "informational"(ptr addrspace(1) %alias) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @handled_intrinsic_ordinary_operand()
; The identity intrinsic's ordinary argument and the informational user remain
; non-escaping.
; CHECK-NOT: jeandle.new_instance
; CHECK: call ptr addrspace(1) @llvm.launder.invariant.group.p1(ptr addrspace(1) poison)
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: [ "informational"(ptr addrspace(1) %alias) ]

define void @real_allocation_stops_dependency_walk()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %virtual = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72208 to ptr), i32 16, i1 false)
      to label %alloc.real unwind label %unwind

alloc.real:
  ; A null klass makes this allocation ineligible before PEA registers a
  ; VirtualObject.  Its allocation-safepoint bundle independently describes
  ; %virtual.
  %real = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr null, i32 16, i1 false)
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %virtual) ]
      to label %body unwind label %unwind

body:
  ; Reaching the surviving real allocation must stop the final dependency
  ; walk.  The walk must not recurse into %real's own call operands/bundle and
  ; spuriously suppress %virtual.
  call void @llvm.sideeffect()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %real) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @real_allocation_stops_dependency_walk()
; CHECK-NOT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 72208
; CHECK: %[[REAL:[A-Za-z0-9._]+]] = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr null, i32 16, i1 false)
; CHECK-SAME: [ "deopt"(i32 99, i32 99,
; CHECK-SAME: i64 262156, i64 72208, i32 0,
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK: call void @llvm.sideeffect()
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 12,
; CHECK-SAME: ptr addrspace(1) %[[REAL]]) ]
; CHECK-NOT: poison

!java-method-compilation = !{}
