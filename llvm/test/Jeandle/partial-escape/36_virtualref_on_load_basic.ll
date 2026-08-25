; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; VirtualRef-on-load — recurse / load-of-inner.
;
; The outer is a plain instance whose tracked field (offset 8) holds the
; inner array's pointer (a VirtualRef field entry). Loading outer.field
; should *not* mark either object ineligible: it must forward the load to
; the inner virtual's allocation and install a virtual alias so that the
; downstream jeandle.arraylength on the loaded value resolves to the
; inner ObjectID and folds to the inner's compile-time length. Nothing
; escapes; both allocations and the field store all disappear.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare i32 @__gxx_personality_v0(...)

define i32 @test_virtualref_on_load_basic() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
              ptr inttoptr (i64 12345 to ptr), i32 7, i32 44, i32 16, i32 1048576)
           to label %nA unwind label %u1
nA:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %nB unwind label %u2
nB:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot unordered, align 8
  %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %slot unordered, align 8
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %loaded)
  ret i32 %len
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; CHECK-LABEL: define i32 @test_virtualref_on_load_basic
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraylength
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 7

!java-method-compilation = !{}
