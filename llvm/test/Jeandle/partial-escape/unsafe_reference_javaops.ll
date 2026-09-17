; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Plain unordered Unsafe reference accesses are field operations on a virtual
; object. PEA records the put in FieldStates, folds the get from that state,
; and replays the physical field type (AS3 when compressed oops is enabled)
; only if the object later needs materialization. The ordered/volatile Unsafe
; variants are intentionally not covered by these folds.
target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.unsafe_get_reference(
    ptr addrspace(1), i64)
declare hotspotcc void @jeandle.unsafe_put_reference(
    ptr addrspace(1), i64, ptr addrspace(1))
declare hotspotcc i32 @jeandle.reference_refers_to(
    ptr addrspace(1), ptr addrspace(1))
declare hotspotcc void @sink(ptr addrspace(1))

declare i32 @__gxx_personality_v0(...)

define i32 @test_unsafe_reference_null() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1001 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  call hotspotcc void @jeandle.unsafe_put_reference(
      ptr addrspace(1) %o, i64 16, ptr addrspace(1) null)
  %v = call hotspotcc ptr addrspace(1) @jeandle.unsafe_get_reference(
      ptr addrspace(1) %o, i64 16)
  %isnull = icmp eq ptr addrspace(1) %v, null
  %result = zext i1 %isnull to i32
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_unsafe_reference_null
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.unsafe_put_reference
; CHECK-NOT: jeandle.unsafe_get_reference
; CHECK: %isnull = icmp eq ptr addrspace(1) null, null
; CHECK: ret i32 %result

define i32 @test_unsafe_reference_virtual() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1002 to ptr), i32 32, i1 false)
      to label %inner unwind label %unwind
inner:
  %inner.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1003 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  call hotspotcc void @jeandle.unsafe_put_reference(
      ptr addrspace(1) %outer, i64 16, ptr addrspace(1) %inner.obj)
  %v = call hotspotcc ptr addrspace(1) @jeandle.unsafe_get_reference(
      ptr addrspace(1) %outer, i64 16)
  %same = icmp eq ptr addrspace(1) %v, %inner.obj
  %result = zext i1 %same to i32
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_unsafe_reference_virtual
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.unsafe_put_reference
; CHECK-NOT: jeandle.unsafe_get_reference
; CHECK: %result = zext i1 true to i32
; CHECK: ret i32 %result

define i32 @test_reference_refers_to(ptr addrspace(1) %reference) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %object = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1004 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %result = call hotspotcc i32 @jeandle.reference_refers_to(
      ptr addrspace(1) %reference, ptr addrspace(1) %object)
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_reference_refers_to
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.reference_refers_to
; CHECK: fence syncscope("singlethread") seq_cst
; CHECK: ret i32 0

define void @test_unsafe_reference_replay() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1006 to ptr), i32 32, i1 false)
      to label %inner unwind label %unwind
inner:
  %inner.obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1007 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  call hotspotcc void @jeandle.unsafe_put_reference(
      ptr addrspace(1) %outer, i64 16, ptr addrspace(1) %inner.obj)
  call hotspotcc void @sink(ptr addrspace(1) %outer)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_unsafe_reference_replay
; CHECK-NOT: jeandle.unsafe_put_reference
; CHECK: addrspacecast ptr addrspace(1)
; CHECK: store atomic ptr addrspace(3)
; CHECK: call hotspotcc void @sink

!java-method-compilation = !{}
