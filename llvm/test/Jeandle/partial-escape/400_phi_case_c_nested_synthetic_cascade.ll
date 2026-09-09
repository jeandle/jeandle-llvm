; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=8 %s | FileCheck %s --check-prefix=REPEAT
; RUN: opt -disable-output -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-dump-pea-stats \
; RUN:   -jeandle-pea-analyze-function=test_casec_nested_cascade %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=STATS

; Two sequential Case-C merges build a synthetic-source DAG two levels deep:
;
;   M1: %p1 = phi [ %A, %as ], [ %B, %bs ]         -> S1 over {A, B}
;   M2: %p2 = phi [ %p1, %d ], [ %C, %cs ]         -> S2 over {S1, C}
;
; @sink(%p2) makes S2 real. PEA retains A, B, and C at their original
; allocation sites so both %p1 and %p2 are real merged identities. It keeps
; all source stores scalar-replaced and replays S2's complete current state
; once onto %p2; neither synthetic may borrow a source AllocationCall as a
; materialization target.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_nested_cascade(i1 %c1, i1 %c2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c1, label %a, label %b
a:
  %A = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       [ "deopt"(i32 40001) ]
       to label %as unwind label %u
as:
  %af = getelementptr inbounds i8, ptr addrspace(1) %A, i64 8
  store atomic i32 61, ptr addrspace(1) %af unordered, align 4
  br label %m1
b:
  %B = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       [ "deopt"(i32 40002) ]
       to label %bs unwind label %u
bs:
  %bf = getelementptr inbounds i8, ptr addrspace(1) %B, i64 8
  store atomic i32 62, ptr addrspace(1) %bf unordered, align 4
  br label %m1
m1:
  %p1 = phi ptr addrspace(1) [ %A, %as ], [ %B, %bs ]
  %p1.post = getelementptr inbounds i8, ptr addrspace(1) %p1, i64 16
  store atomic i32 71, ptr addrspace(1) %p1.post unordered, align 4
  br i1 %c2, label %c, label %d
c:
  %C = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
       [ "deopt"(i32 40003) ]
       to label %cs unwind label %u
cs:
  %cf = getelementptr inbounds i8, ptr addrspace(1) %C, i64 8
  store atomic i32 63, ptr addrspace(1) %cf unordered, align 4
  br label %m2
d:
  br label %m2
m2:
  %p2 = phi ptr addrspace(1) [ %p1, %d ], [ %C, %cs ]
  %p2.post = getelementptr inbounds i8, ptr addrspace(1) %p2, i64 24
  store atomic i32 72, ptr addrspace(1) %p2.post unordered, align 4
  call void @sink(ptr addrspace(1) %p2)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_casec_nested_cascade
; CHECK: %A = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: as:
; CHECK-NEXT: br label %m1
; CHECK: %B = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: bs:
; CHECK-NEXT: br label %m1
; CHECK: %p1 = phi ptr addrspace(1)
; CHECK-NEXT: %[[F1:[-A-Za-z$._0-9]+]] = phi i32 [ 61, %as ], [ 62, %bs ]
; CHECK: %C = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: cs:
; CHECK-NEXT: br label %m2
; CHECK: %p2 = phi ptr addrspace(1)
; CHECK-NEXT: %[[F2:[-A-Za-z$._0-9]+]] = phi i32 [ %[[F1]], %d ], [ 63, %cs ]
; CHECK-NEXT: %[[F3:[-A-Za-z$._0-9]+]] = phi i32 [ 71, %d ], [ 0, %cs ]
; CHECK: %[[SLOT8:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %p2, i64 8
; CHECK-NEXT: store atomic i32 %[[F2]], ptr addrspace(1) %[[SLOT8]] unordered, align 4
; CHECK-NEXT: %[[SLOT16:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %p2, i64 16
; CHECK-NEXT: store atomic i32 %[[F3]], ptr addrspace(1) %[[SLOT16]] unordered, align 4
; CHECK-NEXT: %[[SLOT24:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %p2, i64 24
; CHECK-NEXT: store atomic i32 72, ptr addrspace(1) %[[SLOT24]] unordered, align 4
; CHECK: call void @sink
; CHECK-NOT: poison

; A second complete iterative pipeline is idle: the three source allocations
; and the one three-field replay are neither removed nor duplicated.
; REPEAT-LABEL: define void @test_casec_nested_cascade(
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %A = {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %B = {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT: %C = {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32 61
; REPEAT-NOT: store atomic i32 62
; REPEAT-NOT: store atomic i32 63
; REPEAT-NOT: store atomic i32 71
; REPEAT: store atomic i32
; REPEAT: store atomic i32
; REPEAT: store atomic i32 72
; REPEAT-NOT: store atomic i32
; REPEAT: call void @sink
; REPEAT-NOT: @jeandle.new_instance
; REPEAT-NOT: store atomic i32
; REPEAT-NOT: call void @sink
; REPEAT-NOT: poison
; STATS: PEA stats @test_casec_nested_cascade: NeverEscapes=0 PartiallyEscapes=3 AlwaysEscapes=0

!java-method-compilation = !{}
