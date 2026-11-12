; RUN: opt -S -verify-each -passes='partial-escape-iterative' -jeandle-pea-iterations=8 -jeandle-dump-pea-ir=clone_boundary %s -o %t.once 2> %t.trace
; RUN: FileCheck %s < %t.once
; RUN: FileCheck %s --check-prefix=IDLE < %t.trace
; RUN: opt -S -verify-each -passes='partial-escape-iterative,partial-escape-iterative' -jeandle-pea-iterations=8 %s -o %t.twice
; RUN: diff %t.once %t.twice
;
; CloneSource terminates a physical batch. Empty-field owners still belong to
; the publication set; independently observed objects cannot share a batch.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1))
declare hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1))
declare void @sink(ptr addrspace(1), ptr addrspace(1), ptr addrspace(1), ptr addrspace(1))
; IDLE: PEA-DUMP after iter={{[0-7]}} function clone_boundary transform_idle=1
; CHECK-LABEL: define void @clone_boundary(
; CHECK: store atomic i32 %x,
; CHECK-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1){{[^,%]*}} %a, i32 1, ptr addrspace(1){{[^,%]*}} %b, i32 2)
; CHECK-NEXT: call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %b)
; CHECK: store atomic i32 %y,
; CHECK: store atomic i32 %z,
; CHECK-NEXT: call hotspotcc void (i32, ...) @jeandle.membar_replay_publish(i32 2, ptr addrspace(1){{[^,%]*}} %c, i32 1, ptr addrspace(1){{[^,%]*}} %d, i32 1)
; CHECK-NEXT: call void @sink
; CHECK-NEXT: ret void
define void @clone_boundary(i32 %x, i32 %y, i32 %z) gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %c = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %d = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %af unordered, align 4
  call hotspotcc void @jeandle.membar_constructor_freeze(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.membar_clone_source(ptr addrspace(1) %b)
  %cf = getelementptr inbounds i8, ptr addrspace(1) %c, i64 16
  store atomic i32 %y, ptr addrspace(1) %cf unordered, align 4
  %df = getelementptr inbounds i8, ptr addrspace(1) %d, i64 16
  store atomic i32 %z, ptr addrspace(1) %df unordered, align 4
  call void @sink(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c, ptr addrspace(1) %d)
  ret void
}

; CHECK-LABEL: define void @separate_observers(
; CHECK: store atomic i32 %x,
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %a)
; CHECK-NEXT: call void @sink
; CHECK: store atomic i32 %y,
; CHECK-NEXT: call hotspotcc void @jeandle.membar_allocation_init(ptr addrspace(1) %b)
; CHECK-NEXT: call void @sink
; CHECK-NEXT: ret void
define void @separate_observers(i32 %x, i32 %y) gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 23456 to ptr), i32 24, i1 false)
  %af = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %af unordered, align 4
  %bf = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic i32 %y, ptr addrspace(1) %bf unordered, align 4
  call void @sink(ptr addrspace(1) %a, ptr addrspace(1) null, ptr addrspace(1) null, ptr addrspace(1) null)
  call void @sink(ptr addrspace(1) %b, ptr addrspace(1) null, ptr addrspace(1) null, ptr addrspace(1) null)
  ret void
}
!java-method-compilation = !{}
