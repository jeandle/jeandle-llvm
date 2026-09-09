; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s --check-prefix=IR

; Model a later PEA round: the bundle already contains a Point[] descriptor,
; while the current round creates a synthetic Point at a Case-C merge.  The
; array element and a second scope root both hold that synthetic Point.
;
; Analysis ObjectIDs are round-local and must never be copied to the deopt
; wire.  The final reachable object graph is numbered densely in deterministic
; pool order: the existing array is wire ID 0 and the current Point is wire
; ID 1.  Every descriptor edge and scope root must use those wire IDs.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1) nounwind
declare void @safepoint()

define void @cross_round_deopt_pool(i1 %choose) gc "hotspotgc" {
entry:
  br i1 %choose, label %left, label %right

left:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74301 to ptr), i32 24, i1 false) [ "deopt"(i32 743011) ]
  %a8 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 41, ptr addrspace(1) %a8 unordered, align 4
  %a16 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 101, ptr addrspace(1) %a16 unordered, align 4
  br label %merge

right:
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74301 to ptr), i32 24, i1 false) [ "deopt"(i32 743012) ]
  %b8 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 42, ptr addrspace(1) %b8 unordered, align 4
  %b16 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 102, ptr addrspace(1) %b16 unordered, align 4
  br label %merge

merge:
  %p = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  call void @safepoint()
      [ "deopt"(i32 743, i32 743,
               ; Existing Point[] descriptor, legacy wire ID 2.
               i64 8590196749, i64 74302, i32 1,
               ; element @16, LocalType/T_OBJECT, initially current %p.
               i64 68719476748, ptr addrspace(1) %p,
               ; Local 0 refers to the existing array.
               i64 8590458892, i32 2,
               ; Expression-stack slot 0 holds the current synthetic Point.
               i64 65548, ptr addrspace(1) %p) ]
  ret void
}

; IR-LABEL: define void @cross_round_deopt_pool(
; The current Point is fully virtualized.
; IR-NOT: call {{.*}}@jeandle.new_instance
; IR-NOT: store
; IR: %[[F8:[^ ]+]] = phi i32 [ 41, %left ], [ 42, %right ]
; IR: %[[F16:[^ ]+]] = phi i32 [ 101, %left ], [ 102, %right ]
;
; Match the entire bundle as one contiguous value.  This permits exactly two
; descriptors, in deterministic pool order, and forbids stale or duplicate
; descriptors and trailing operands:
;   wire ID 0: existing Point[], element -> wire ID 1
;   wire ID 1: current Point, fields -> the two Case-C scalar phis
;   roots: Point[] -> wire ID 0, Point -> wire ID 1
; IR: call void @safepoint() [ "deopt"(i32 743, i32 743, i64 262157, i64 74302, i32 1, i64 68720001036, i32 1, i64 4295229452, i64 74301, i32 2, i64 34359738378, i32 %[[F8]], i64 68719476746, i32 %[[F16]], i64 524300, i32 0, i64 4295557132, i32 1) ]{{$}}
; IR-NOT: addrspace(1) %p
; IR-NOT: poison

!java-method-compilation = !{}
