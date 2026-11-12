; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=PEA
; RUN: opt -S -verify-each -passes='function(partial-escape-iterative,insert-gc-barriers),java-operation-lower<phase=1>' -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=GC
;
; A cyclic graph preserves narrow-oop lanes and every collector pre/post pair.
; Mutator publication remains after all replay stores and collector operations.
target datalayout = "e-p:64:64-p1:64:64-p3:32:32-i64:64-n8:16:32:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))
declare void @sink(ptr addrspace(1), ptr addrspace(1))
; PEA-LABEL: define void @cycle(
; PEA: store atomic ptr addrspace(3)
; PEA: store atomic ptr addrspace(3)
; PEA: store atomic ptr addrspace(3) null
; PEA-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2,
; PEA-NEXT: call void @sink
; PEA-NEXT: ret void
; GC-LABEL: define void @cycle(
; GC: call hotspotcc void @jeandle.pre_barrier
; GC-NEXT: store atomic ptr addrspace(3)
; GC: call hotspotcc void @jeandle.post_barrier
; GC: call hotspotcc void @jeandle.pre_barrier
; GC-NEXT: store atomic ptr addrspace(3)
; GC: call hotspotcc void @jeandle.post_barrier
; GC: call hotspotcc void @jeandle.pre_barrier
; GC-NEXT: store atomic ptr addrspace(3) null
; GC-NEXT: fence release
; GC-NEXT: call void @sink
; GC-NEXT: ret void
define void @cycle() gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %an = addrspacecast ptr addrspace(1) %a to ptr addrspace(3)
  %bn = addrspacecast ptr addrspace(1) %b to ptr addrspace(3)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic ptr addrspace(3) %bn, ptr addrspace(1) %af unordered, align 4
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic ptr addrspace(3) %an, ptr addrspace(1) %bf unordered, align 4
  %nullfield = getelementptr inbounds i8, ptr addrspace(1) %a, i64 20
  store atomic ptr addrspace(3) null, ptr addrspace(1) %nullfield unordered, align 4
  call void @sink(ptr addrspace(1) %a, ptr addrspace(1) %b)
  ret void
}
!java-method-compilation = !{}
