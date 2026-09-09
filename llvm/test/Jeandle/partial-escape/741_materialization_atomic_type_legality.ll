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

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

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
; CHECK: store atomic <4 x i32> %value, ptr addrspace(1) %pea.matslot unordered, align 16
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
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
; CHECK: store atomic <2 x ptr addrspace(1)> %value, ptr addrspace(1) %pea.matslot unordered, align 16
; CHECK: ret ptr addrspace(1) %obj

!java-method-compilation = !{}
