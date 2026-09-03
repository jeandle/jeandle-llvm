; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Select of derived-GEP arms of TWO DIFFERENT virtual objects. %g1 = gep %o1,
; 16; %g2 = gep %o2, 16. resolveVirtualRef can't pick a common ObjectID, and
; both arms are derived pointers computed before any materialize point, so PEA
; keeps BOTH objects real (markIneligible) rather than materializing at the
; select, which would poison both arms. Both allocations survive and the
; select/load read valid addresses.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_select_different_objects_derived_gep(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 1 to ptr), i32 32, i1 false)
         to label %n unwind label %u
n:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 2 to ptr), i32 32, i1 false)
         to label %m unwind label %u
m:
  %g1 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 16
  %g2 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 16
  store atomic i32 11, ptr addrspace(1) %g1 unordered, align 4
  store atomic i32 22, ptr addrspace(1) %g2 unordered, align 4
  %sel = select i1 %c, ptr addrspace(1) %g1, ptr addrspace(1) %g2
  %r = load atomic i32, ptr addrspace(1) %sel unordered, align 4
  call void @use(i32 %r)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_select_different_objects_derived_gep
; CHECK-NOT: getelementptr{{.*}}poison
; Both allocations stay real; the GEPs keep real bases; the load survives.
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: load atomic i32, ptr addrspace(1) %sel

!java-method-compilation = !{}
