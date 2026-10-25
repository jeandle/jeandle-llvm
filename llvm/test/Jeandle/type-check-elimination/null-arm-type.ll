; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/null-arm-type.cblog %s 2>&1 | FileCheck %s

; Literal null (and poison) PHI/select arms are vacuous under JavaType's
; non-null oop contract — same rule as the CFG engine's null-edge skip — so a
; lazy-initialization pattern keeps its typed arm. Undef arms stay absorbing:
; an undef arm can materialize an arbitrary oop.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

; freeze(phi [null, entry], [loaded, latch]): the base engine types the phi
; through its non-null arm only, and the noundef load lets the freeze forward
; the type. The probe folds true.
define i1 @freeze_of_lazy_init_phi(i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %first, label %warm
first:
  br label %m
warm:
  %loaded = load ptr addrspace(1), ptr addrspace(1) null, !java-klass !0, !noundef !1
  br label %m
m:
  %p = phi ptr addrspace(1) [ null, %first ], [ %loaded, %warm ]
  %f = freeze ptr addrspace(1) %p
  ; CHECK-LABEL: @freeze_of_lazy_init_phi(
  ; CHECK: %f = freeze ptr addrspace(1) %p
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %f)
  ret i1 %r
}

; Same shape without the freeze: the phi itself carries the typed arm.
define i1 @lazy_init_phi(i1 %c) gc "hotspotgc" {
entry:
  br i1 %c, label %first, label %warm
first:
  br label %m
warm:
  %loaded = load ptr addrspace(1), ptr addrspace(1) null, !java-klass !0
  br label %m
m:
  %p = phi ptr addrspace(1) [ null, %first ], [ %loaded, %warm ]
  ; CHECK-LABEL: @lazy_init_phi(
  ; CHECK: %p = phi ptr addrspace(1)
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %p)
  ret i1 %r
}

; A poison arm is equally vacuous: selecting it and using the result as an
; oop is immediate UB.
define i1 @poison_select_arm(i1 %c) gc "hotspotgc" {
entry:
  %loaded = load ptr addrspace(1), ptr addrspace(1) null, !java-klass !0
  %s = select i1 %c, ptr addrspace(1) %loaded, ptr addrspace(1) poison
  ; CHECK-LABEL: @poison_select_arm(
  ; CHECK: %s = select i1 %c
  ; CHECK-NEXT: ret i1 true
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %s)
  ret i1 %r
}

; An undef arm can materialize an arbitrary oop when selected, so it must
; stay absorbing and the probe stays live.
define i1 @undef_select_arm_stays_unknown(i1 %c) gc "hotspotgc" {
entry:
  %loaded = load ptr addrspace(1), ptr addrspace(1) null, !java-klass !0
  %s = select i1 %c, ptr addrspace(1) %loaded, ptr addrspace(1) undef
  ; CHECK-LABEL: @undef_select_arm_stays_unknown(
  ; CHECK: %s = select i1 %c
  ; CHECK-NEXT: %r = call i1 @jeandle.check_instanceof
  ; CHECK-NEXT: ret i1 %r
  %r = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 2 to ptr addrspace(0)), ptr addrspace(1) nonnull %s)
  ret i1 %r
}

!0 = !{i64 2}
!1 = !{}
!java-method-compilation = !{}
