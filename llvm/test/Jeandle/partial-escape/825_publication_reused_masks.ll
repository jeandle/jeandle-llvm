; RUN: opt -S -verify-each -passes='require<partial-escape-analysis>,partial-escape-transform' %s | FileCheck %s
; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 -jeandle-dump-pea-ir=preserve_freeze %s -o %t 2> %t.trace
; RUN: FileCheck %s < %t
; RUN: FileCheck %s --check-prefix=IDLE < %t.trace
;
; Every reused legacy group's pending freeze must enter its own batch entry,
; including owners other than the representative replay effect.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1))
declare void @sink(ptr addrspace(1), ptr addrspace(1))
; CHECK-LABEL: define void @preserve_freeze(
; CHECK: store atomic i32 %x,
; CHECK: store atomic i32 %y,
; CHECK-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1){{[^,%]*}} %a, i32 3, ptr addrspace(1){{[^,%]*}} %b, i32 3)
; CHECK-NEXT: call void @sink
; CHECK-NEXT: ret void
; IDLE: PEA-DUMP after iter={{[0-7]}} function preserve_freeze transform_idle=1
define void @preserve_freeze(i32 %x, i32 %y) gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %as = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %as unordered, align 4
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %a)
  %bs = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 %y, ptr addrspace(1) %bs unordered, align 4
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %b)
  %ar = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %ar unordered, align 4
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %a)
  %br = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 %y, ptr addrspace(1) %br unordered, align 4
  call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %b)
  call void @sink(ptr addrspace(1) %a, ptr addrspace(1) %b)
  ret void
}
!java-method-compilation = !{}
