; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Irreducible region whose VIRTUAL VO would cross the cycle. %o is
; allocated in %entry and used by @sink inside both cycle nodes.
; LoopInfo does not recognise the cycle as a natural loop, so
; processLoop is never invoked; the outer RPO walk handles each block
; once. The first escape inside the cycle (whichever block RPO visits
; first) classifies the object as escaping; the original alloc survives
; in IR and the analyzer does not crash. This is the "alloc whose virtual
; would cross the irreducible region" case.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare void @use_after(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_irreducible_with_alloc(i1 %p) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %dispatch unwind label %u
dispatch:
  br i1 %p, label %a, label %b
a:
  call void @sink(ptr addrspace(1) %o)
  br i1 %p, label %b, label %exit
b:
  call void @sink(ptr addrspace(1) %o)
  br i1 %p, label %a, label %exit
exit:
  call void @use_after(ptr addrspace(1) %o)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The original alloc survives (retained at the escape), no crash. All
; @sink and @use_after calls intact.
; CHECK-LABEL: define void @test_irreducible_with_alloc
; CHECK: invoke {{.*}}@jeandle.new_instance
; CHECK-DAG: call void @sink
; CHECK-DAG: call void @sink
; CHECK-DAG: call void @use_after

!java-method-compilation = !{}
