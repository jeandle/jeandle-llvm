; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Recursive nested-virtual materialization: an outer object whose tracked
; field references an inner virtual object. Returning the outer is an escape;
; PEA retains BOTH original allocations (inner first, with lower SeqNo) and
; replays a store of the inner pointer into the outer's field.
;
; Each allocation invoke gets its own unwind landingpad to keep the multi-
; predecessor merge from marking later-allocated objects ineligible at a
; shared unwind block.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @test_nested_escape() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %nA unwind label %u1
nA:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %nB unwind label %u2
nB:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %slot unordered, align 8
  ret ptr addrspace(1) %outer
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

; CHECK-LABEL: define ptr addrspace(1) @test_nested_escape
; The inner allocation invoke (klass 12345) is retained.
; CHECK: %[[INNER:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; The outer allocation invoke (klass 67890) is retained.
; CHECK: %[[OUTER:[A-Za-z0-9._]+]] = invoke hotspotcc{{.*}}ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
; CHECK-NEXT: to label %{{.*}} unwind label %{{.*}}
; A replayed store writes the inner OrigAlloc at offset 8 of the outer.
; A reference field is replayed with natural 8-byte (heap pointer width) alignment.
; CHECK: %[[SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds i8, ptr addrspace(1) %[[OUTER]], i64 8
; CHECK: store atomic ptr addrspace(1) %[[INNER]], ptr addrspace(1) %[[SLOT]] unordered, align 8
; CHECK: ret ptr addrspace(1) %[[OUTER]]

!java-method-compilation = !{}
