; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A PEA-folded identity comparison controls a branch whose impossible arm
; would otherwise materialize the virtual receiver. The analyzer must exclude
; that arm before merging object state; no pre-PEA simplifycfg run is present.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @folded_branch_dead_edge()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 71701 to ptr), i32 24, i1 false)
      to label %dispatch unwind label %alloc.unwind

dispatch:
  %field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 41, ptr addrspace(1) %field unordered, align 4
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %dead, label %live

dead:
  call void @escape(ptr addrspace(1) %o)
  br label %merge

live:
  br label %merge

merge:
  %value = load atomic i32, ptr addrspace(1) %field unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @folded_branch_dead_edge()
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @escape
; CHECK-NOT: alloc.unwind:
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK-NOT: poison
; CHECK: ret i32 41

!java-method-compilation = !{}
