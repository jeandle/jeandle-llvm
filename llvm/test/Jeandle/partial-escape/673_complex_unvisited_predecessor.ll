; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=NOPOISON

; The SCC {left, right, merge, cycle} has two entries and no natural-loop
; header: entry can reach both left and right directly, while merge can return
; to either arm through cycle.  In RPO one of merge's reachable predecessors
; is necessarily unvisited when the first SCC block is processed.  A partial
; predecessor state must not let PEA fold the merged load to either arm's
; constant.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink_i32(i32)
declare i32 @__gxx_personality_v0(...)

define void @irreducible_unvisited_predecessor(i1 %entry_side, i1 %again,
                                               i1 %next_side)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
           ptr inttoptr (i64 67301 to ptr), i32 32, i1 false)
       to label %dispatch unwind label %unwind

dispatch:
  br i1 %entry_side, label %left, label %right

left:
  %lf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 11, ptr addrspace(1) %lf unordered, align 4
  br label %merge

right:
  %rf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 22, ptr addrspace(1) %rf unordered, align 4
  br label %merge

merge:
  %mf = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %mf unordered, align 4
  call void @sink_i32(i32 %value)
  br i1 %again, label %cycle, label %exit

cycle:
  br i1 %next_side, label %left, label %right

exit:
  ret void

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @irreducible_unvisited_predecessor
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: left:
; CHECK: store atomic i32 11, ptr addrspace(1) %lf unordered, align 4
; CHECK: right:
; CHECK: store atomic i32 22, ptr addrspace(1) %rf unordered, align 4
; CHECK: merge:
; CHECK: %value = load atomic i32, ptr addrspace(1) %mf unordered, align 4
; CHECK: call void @sink_i32(i32 %value)
; CHECK-NOT: call void @sink_i32(i32 11)
; CHECK-NOT: call void @sink_i32(i32 22)
; CHECK-NOT: poison

; NOPOISON-LABEL: define void @irreducible_unvisited_predecessor
; NOPOISON-NOT: poison

!java-method-compilation = !{}
