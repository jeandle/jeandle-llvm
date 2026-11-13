; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,insert-gc-barriers" %s | FileCheck %s --check-prefix=GC
; RUN: opt -disable-output -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,require<partial-escape-analysis>,partial-escape-transform" %s
; RUN: opt -passes=verify -disable-output %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A field value is replayed with an atomic unordered store when its virtual
; receiver materializes.  The source store may use any sized first-class LLVM
; type, but an atomic store is legal only for an integer, pointer, floating
; point, or fixed vector whose total bit width is at least eight and a power of
; two.  Unsupported values must materialize before their original non-atomic
; store; legal fixed vectors remain virtual until the return escape.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

define ptr addrspace(1) @reject_i24(i24 %value) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74101 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store i24 %value, ptr addrspace(1) %slot, align 4
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @reject_i24(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
; CHECK: store i24 %value, ptr addrspace(1) %slot, align 4
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @reject_x86_fp80(x86_fp80 %value) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74102 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 16
  store x86_fp80 %value, ptr addrspace(1) %slot, align 16
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @reject_x86_fp80(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %obj, i64 16
; CHECK: store x86_fp80 %value, ptr addrspace(1) %slot, align 16
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @reject_fixed_vector_96(<3 x i32> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74103 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <3 x i32> %value, ptr addrspace(1) %slot, align 16
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @reject_fixed_vector_96(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
; CHECK: store <3 x i32> %value, ptr addrspace(1) %slot, align 16
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @reject_scalable_vector(<vscale x 2 x i32> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74104 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <vscale x 2 x i32> %value, ptr addrspace(1) %slot, align 8
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @reject_scalable_vector(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
; CHECK: store <vscale x 2 x i32> %value, ptr addrspace(1) %slot, align 8
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @reject_aggregate() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74105 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store { i32, i32 } { i32 1, i32 2 }, ptr addrspace(1) %slot, align 4
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @reject_aggregate(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
; CHECK: store { i32, i32 } { i32 1, i32 2 }, ptr addrspace(1) %slot, align 4
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @accept_fixed_vector_128(<4 x i32> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74106 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <4 x i32> %value, ptr addrspace(1) %slot, align 16
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @accept_fixed_vector_128(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic i64 %{{[^ ]+}}, ptr addrspace(1) %pea.matslot unordered, align 8
; CHECK-NEXT: %[[V128_HIGH:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 16
; CHECK-NEXT: store atomic i64 %{{[^ ]+}}, ptr addrspace(1) %[[V128_HIGH]] unordered, align 8
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @accept_fixed_vector_8(<8 x i1> %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74107 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <8 x i1> %value, ptr addrspace(1) %slot, align 1
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @accept_fixed_vector_8(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK: store atomic <8 x i1> %value, ptr addrspace(1) %pea.matslot unordered, align 1
; CHECK: ret ptr addrspace(1) %obj

; Java boolean fields and boolean[] elements use i8 physical storage.  Keep
; that representation eligible even though the logical Java type is boolean.
define ptr addrspace(1) @accept_i8_physical_boolean(i8 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74108 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store i8 %value, ptr addrspace(1) %slot, align 1
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @accept_i8_physical_boolean(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK: store atomic i8 %value, ptr addrspace(1) %pea.matslot unordered, align 1
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @accept_fixed_pointer_vector(
    <2 x ptr addrspace(1)> %value) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74109 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <2 x ptr addrspace(1)> %value, ptr addrspace(1) %slot, align 16
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @accept_fixed_pointer_vector(
; CHECK: %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %[[LANE0:[^ ]+]] = extractelement <2 x ptr addrspace(1)> %value, i64 0
; CHECK-NEXT: %[[LANE1:[^ ]+]] = extractelement <2 x ptr addrspace(1)> %value, i64 1
; CHECK-NEXT: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic ptr addrspace(1) %[[LANE0]], ptr addrspace(1) %pea.matslot unordered, align 8
; CHECK-NEXT: %[[REF_HIGH:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %[[LANE1]], ptr addrspace(1) %[[REF_HIGH]] unordered, align 8
; CHECK: ret ptr addrspace(1) %obj

define ptr addrspace(1) @accept_fixed_narrow_pointer_vector(
    <2 x ptr addrspace(3)> %value) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 74110 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 8
  store <2 x ptr addrspace(3)> %value, ptr addrspace(1) %slot, align 8
  ret ptr addrspace(1) %obj
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define ptr addrspace(1) @accept_fixed_narrow_pointer_vector(
; CHECK: %[[NARROW0:[^ ]+]] = extractelement <2 x ptr addrspace(3)> %value, i64 0
; CHECK-NEXT: %[[NARROW1:[^ ]+]] = extractelement <2 x ptr addrspace(3)> %value, i64 1
; CHECK-NEXT: %[[NARROW_SLOT0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK-NEXT: store atomic ptr addrspace(3) %[[NARROW0]], ptr addrspace(1) %[[NARROW_SLOT0]] unordered, align 4
; CHECK-NEXT: %[[NARROW_SLOT1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 12
; CHECK-NEXT: store atomic ptr addrspace(3) %[[NARROW1]], ptr addrspace(1) %[[NARROW_SLOT1]] unordered, align 4
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; CHECK-NEXT: ret ptr addrspace(1) %obj

!java-method-compilation = !{}

; GC-LABEL: define ptr addrspace(1) @accept_fixed_pointer_vector(
; GC: %[[G0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; GC-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %[[G0]])
; GC-NEXT: store atomic ptr addrspace(1) %[[R0:[^ ]+]], ptr addrspace(1) %[[G0]] unordered, align 8
; GC-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %[[G0]], ptr addrspace(1) %[[R0]])
; GC-NEXT: %[[G1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 16
; GC-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %[[G1]])
; GC-NEXT: store atomic ptr addrspace(1) %[[R1:[^ ]+]], ptr addrspace(1) %[[G1]] unordered, align 8
; GC-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %[[G1]], ptr addrspace(1) %[[R1]])
; GC-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; GC-NEXT: ret ptr addrspace(1) %obj
; GC-LABEL: define ptr addrspace(1) @accept_fixed_narrow_pointer_vector(
; GC: %[[NG0:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; GC-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %[[NG0]])
; GC-NEXT: store atomic ptr addrspace(3) %[[NR0:[^ ]+]], ptr addrspace(1) %[[NG0]] unordered, align 4
; GC-NEXT: %[[NW0:[^ ]+]] = addrspacecast ptr addrspace(3) %[[NR0]] to ptr addrspace(1)
; GC-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %[[NG0]], ptr addrspace(1) %[[NW0]])
; GC-NEXT: %[[NG1:[^ ]+]] = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 12
; GC-NEXT: call hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %[[NG1]])
; GC-NEXT: store atomic ptr addrspace(3) %[[NR1:[^ ]+]], ptr addrspace(1) %[[NG1]] unordered, align 4
; GC-NEXT: %[[NW1:[^ ]+]] = addrspacecast ptr addrspace(3) %[[NR1]] to ptr addrspace(1)
; GC-NEXT: call hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %[[NG1]], ptr addrspace(1) %[[NW1]])
; GC-NEXT: call hotspotcc void @jeandle.membar_allocation_init(
; GC-NEXT: ret ptr addrspace(1) %obj
