; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Non-regression: a whole-object select (`select %c, %o, %o`) has
; BOTH arms at offset 0, so the offset guard does NOT trip — the select still
; alias-forwards to %o and the object stays virtual. This preserves the
; legitimate same-offset case (cf. 170/171/330).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_whole_object(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %f0 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store atomic i32 42, ptr addrspace(1) %f0 unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) %o
  %r = load atomic i32, ptr addrspace(1) %sel unordered, align 4
  call void @use(i32 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_whole_object
; The select denotes %o at offset 0 on both arms, so the object is eliminated
; and the load folds to the stored field@0 value (42).
; CHECK-NOT: jeandle.new_instance
; CHECK: call{{.*}}@use(i32 42)

!java-method-compilation = !{}
