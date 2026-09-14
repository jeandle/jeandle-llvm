; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A compressed reference is represented by ptr addrspace(3) and occupies four
; bytes under this DataLayout. PEA must not treat it as an eight-byte wide oop:
; the i32 field immediately following it is a distinct, non-overlapping slot.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_narrow_oop_field_width(ptr addrspace(1) %ref)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind

normal:
  %narrow = addrspacecast ptr addrspace(1) %ref to ptr addrspace(3)
  %ref.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %ref.slot unordered, align 4
  %int.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 20
  store atomic i32 42, ptr addrspace(1) %int.slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %int.slot unordered, align 4
  ret i32 %value

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A never-written compressed-reference field has the narrow null value as its
; Java default.
define ptr addrspace(3) @test_narrow_oop_default()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 67890 to ptr), i32 24, i1 false)
       to label %normal unwind label %unwind

normal:
  %ref.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic ptr addrspace(3), ptr addrspace(1) %ref.slot unordered, align 4
  ret ptr addrspace(3) %value

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_narrow_oop_field_width
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 42

; CHECK-LABEL: define ptr addrspace(3) @test_narrow_oop_default
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: load
; CHECK: ret ptr addrspace(3) null

!java-method-compilation = !{}
