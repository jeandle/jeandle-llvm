; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Lit coverage for `select i1, %virt, null`. The select's two arms
; don't both resolve to the same virtual (one arm is null), so the
; SelectInst arm of propagatePointerAlias falls through to the generic
; escape path which materialises the virtual at the select. The null
; arm survives unchanged.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_select_vo_null(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %sel = select i1 %c, ptr addrspace(1) %o, ptr addrspace(1) null
  call void @sink(ptr addrspace(1) %sel)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The virtual must be materialized (so the sink receives a real pointer
; on the %c=true branch); the select survives as a runtime choice.
; CHECK-LABEL: define void @test_select_vo_null
; CHECK: invoke{{.*}}@jeandle.new_instance
; CHECK: select i1
; CHECK: call void @sink

!java-method-compilation = !{}
