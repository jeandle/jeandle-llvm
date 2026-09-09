; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; The dead structural predecessor is interleaved with two live predecessors.
; PEA must preserve each live field value's original incoming block while the
; dead edge still occupies a full-width poison slot. The final cleanup removes
; that slot and leaves the two live values attached to the right blocks.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @dead_phi_original_index(i1 %choose)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 71901 to ptr), i32 24, i1 false)
      to label %dispatch unwind label %alloc.unwind

dispatch:
  %not.null = icmp ne ptr addrspace(1) %o, null
  br i1 %not.null, label %live.dispatch, label %dead

dead:
  call void @escape(ptr addrspace(1) %o)
  br label %merge

live.dispatch:
  br i1 %choose, label %left, label %right

left:
  %left.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 61, ptr addrspace(1) %left.field unordered, align 4
  br label %merge

right:
  %right.field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 62, ptr addrspace(1) %right.field unordered, align 4
  br label %merge

merge:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @dead_phi_original_index(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @escape
; CHECK-NOT: dead:
; CHECK-NOT: alloc.unwind:
; CHECK: left:
; CHECK: br label %merge
; CHECK: right:
; CHECK: br label %merge
; CHECK: merge:
; CHECK-NEXT: %pea.field.phi = phi i32 [ 62, %right ], [ 61, %left ]
; CHECK-NEXT: ret i32 %pea.field.phi
; CHECK-NOT: poison

!java-method-compilation = !{}
