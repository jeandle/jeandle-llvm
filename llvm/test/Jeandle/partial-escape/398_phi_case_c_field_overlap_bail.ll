; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C — negative test for the Fields-union OVERLAP bail. Both arms
; allocate the same Klass, but their stored field ranges OVERLAP across preds in
; a way no single per-offset type check can see:
;   left  : store i64 at offset 8   -> covers bytes [8, 16)
;   right : store i32 at offset 12  -> covers bytes [12, 16)
; Each per-pred VO is internally consistent (one store each), so the per-entry
; Plans type check passes (offset 8 = i64 only, offset 12 = i32 only). Only the
; Fields-union step catches the conflict: unioning right's i32@12 into a VO that
; already holds i64@8 makes getOrCreateFieldIndex return -1 (overlap). The merge
; must bail, falling through to Case A — both objects materialize at their
; predecessor terminators by retaining their OrigAllocs and replaying the
; tracked fields there. The PHI carries the two source pointers.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_overlap_bail(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
        to label %lstore unwind label %u
lstore:
  %l8 = getelementptr inbounds i8, ptr addrspace(1) %o1, i64 8
  store atomic i64 305419896, ptr addrspace(1) %l8 unordered, align 8
  br label %merge
right:
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
        to label %rstore unwind label %u
rstore:
  %r12 = getelementptr inbounds i8, ptr addrspace(1) %o2, i64 12
  store atomic i32 42, ptr addrspace(1) %r12 unordered, align 4
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %o1, %lstore ], [ %o2, %rstore ]
  call void @sink(ptr addrspace(1) %p)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_overlap_bail
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance
; CHECK: phi ptr addrspace(1)
; CHECK: call void @sink

!java-method-compilation = !{}
