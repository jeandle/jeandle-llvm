; RUN: opt -S -passes='copy-specialization,simplifycfg' -verify-each %s | FileCheck %s

; Dead dynamic clone destinations have no identity or deopt users. Source
; checks and source ordering remain even when the allocation disappears.
@jeandle.personality = global ptr null
@WordSize = constant i32 8
@arrayOopDesc.base_offset_in_bytes.object = constant i32 16
@heapOopSize = constant i32 4
@ArrayOperationPartialInlineSize = constant i32 0
declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)
declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1))
declare hotspotcc void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1))
declare void @observe(ptr addrspace(1))
declare void @payload(ptr addrspace(1), ptr addrspace(1), i64)
define private hotspotcc void @jeandle.clone_payload(ptr addrspace(1) %src, i64 %so, ptr addrspace(1) %dst, i64 %do, i64 %count, i1 %instance) {
  call void @payload(ptr addrspace(1) %src, ptr addrspace(1) %dst, i64 %count)
  ret void
}

define hotspotcc void @unused_dynamic(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret void
}

; CHECK-LABEL: define hotspotcc void @unused_dynamic(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.clone_payload
; CHECK-NOT: @jeandle.copy
; CHECK: ret void

define hotspotcc void @unused_invoke(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
      to label %copy unwind label %unwind
copy:
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define hotspotcc void @unused_invoke(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.clone_payload
; CHECK-NOT: @jeandle.copy
; CHECK: ret void

define hotspotcc void @deopt_identity(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  call void @observe(ptr addrspace(1) null) [ "deopt"(ptr addrspace(1) %dest) ]
  ret void
}

; CHECK-LABEL: define hotspotcc void @deopt_identity(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK: @jeandle.new_array
; CHECK: @jeandle.clone_payload
; CHECK: ret void

define hotspotcc void @unrelated_length(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %arbitrary, i32 0, i32 16, i32 262144, i1 false, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret void
}

; CHECK-LABEL: define hotspotcc void @unrelated_length(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK: @jeandle.new_array
; CHECK: @jeandle.clone_payload
; CHECK: ret void

define hotspotcc void @uninitialized(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 true, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret void
}

; CHECK-LABEL: define hotspotcc void @uninitialized(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.clone_payload
; CHECK: ret void

define hotspotcc void @uncoupled(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #2
  ret void
}

; CHECK-LABEL: define hotspotcc void @uncoupled(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK: @jeandle.new_array
; CHECK: @jeandle.clone_payload
; CHECK: ret void

attributes #0 = { "java-method"="0" }
attributes #1 = { "jeandle.copy.kind"="clone-array" "jeandle.copy.tightly-coupled-allocation" }
attributes #2 = { "jeandle.copy.kind"="clone-array" }
!java-method-compilation = !{}

define hotspotcc void @nullable_source(ptr addrspace(1) %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
  call hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #1
  ret void
}

; CHECK-LABEL: define hotspotcc void @nullable_source(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK: @jeandle.new_array
; CHECK: @jeandle.clone_payload
; CHECK: ret void


define hotspotcc void @unused_reference(ptr addrspace(1) nonnull %src, i32 %arbitrary, i64 %words) #0 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %src)
  %length = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %src)
  %dest = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 %length, i32 0, i32 16, i32 262144, i1 false, i1 false)
  invoke hotspotcc void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dest, i64 16, i64 %words, ptr null, ptr null, i64 0, i64 0) #3
      to label %normal unwind label %unwind
normal:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define hotspotcc void @unused_reference(
; CHECK: call hotspotcc void @jeandle.membar_clone_source
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.clone_payload
; CHECK-NOT: @jeandle.copy
; CHECK: ret void


attributes #3 = { "jeandle.copy.kind"="clone-reference-array" "jeandle.copy.tightly-coupled-allocation" }
