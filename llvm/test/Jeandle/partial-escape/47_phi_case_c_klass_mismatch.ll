; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C klass-mismatch — diamond CFG, both arms allocate DIFFERENT
; Klass values. The Klass-pointer compatibility check in synthesizeCaseC
; fails immediately; analyzer falls through to Case A; both virtuals
; materialize at their predecessor terminators by retaining their source
; allocations. The PHI carries the two OrigAlloc values.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_klass_mismatch(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %o1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
        to label %lcont unwind label %u
lcont:
  br label %merge
right:
  ; A different Klass pointer (constant 67890 vs 12345).
  %o2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
        to label %rcont unwind label %u
rcont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %o1, %lcont ], [ %o2, %rcont ]
  call void @sink(ptr addrspace(1) %p)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_klass_mismatch
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance{{.*}}i64 12345
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_instance{{.*}}i64 67890
; CHECK: phi ptr addrspace(1)
; CHECK: call void @sink

!java-method-compilation = !{}
