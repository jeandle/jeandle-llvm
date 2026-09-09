; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; Regression test for the offset-loss miscompile in Case B/C. An all-derived-
; same-object PHI %p = phi [%sf1,%a1],[%sf2,%a2] (both gep %X,8) is used for a
; field LOAD. Under the reuse-OrigAlloc model the entry alloc %X is retained
; (it dominates both arms and the merge), so both per-arm GEPs of %X stay valid
; and feed the PHI; the tracked stores are replayed onto %X at offset 8 per arm.
; The load stays a real load over the offset-8 derived PHI (field[8] holds 111
; or 222), so it does NOT fold to field[0]'s default 0.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_156_derived_phi_offset(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 32, i1 false)
          to label %cont unwind label %u
cont:
  br i1 %c, label %a1, label %a2
a1:
  %sf1 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store i32 111, ptr addrspace(1) %sf1
  br label %m
a2:
  %sf2 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store i32 222, ptr addrspace(1) %sf2
  br label %m
m:
  %p = phi ptr addrspace(1) [ %sf1, %a1 ], [ %sf2, %a2 ]
  %v = load i32, ptr addrspace(1) %p
  call void @sink_i32(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The original entry alloc %X is RETAINED; the per-arm GEPs of %X are kept
; and feed the merge PHI %p. The load stays a real load over the offset-8
; derived PHI (NOT folded to 0).
; CHECK-LABEL: define void @test_156_derived_phi_offset
; CHECK: %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; The per-arm GEPs of the retained OrigAlloc are kept at offset 8.
; CHECK: %sf1 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; The arm-1 store (111) is replayed onto %X.
; CHECK: store atomic i32 111, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 4
; CHECK: %sf2 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; The arm-2 store (222) is replayed onto %X.
; CHECK: store atomic i32 222, ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 4
; CHECK: %p = phi ptr addrspace(1) [ %sf1, %a1 ], [ %sf2, %a2 ]
; CHECK: load i32, ptr addrspace(1) %p
; CHECK: call void @sink_i32(i32 %v)
; CHECK-NOT: call void @sink_i32(i32 0)
; CHECK-NOT: poison

!java-method-compilation = !{}
