; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; On the first loop-header visit, entry is Live and latch is Unseen. The loop
; body then creates Live and Dead inputs to latch from a PEA-folded branch;
; the next fixpoint visit backfills the live latch contribution without ever
; merging the dead escape arm.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @escape(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @loop_live_dead_unseen(i32 %limit)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72001 to ptr), i32 24, i1 false)
      to label %preheader unwind label %alloc.unwind

preheader:
  br label %loop.header

loop.header:
  %i = phi i32 [ 0, %preheader ], [ %inc, %latch ]
  %not.null = icmp ne ptr addrspace(1) %o, null
  br i1 %not.null, label %live, label %dead

dead:
  call void @escape(ptr addrspace(1) %o)
  br label %latch

live:
  %field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 71, ptr addrspace(1) %field unordered, align 4
  br label %latch

latch:
  %inc = add i32 %i, 1
  %more = icmp ult i32 %inc, %limit
  br i1 %more, label %loop.header, label %exit

exit:
  %reload = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  %value = load atomic i32, ptr addrspace(1) %reload unordered, align 4
  ret i32 %value

alloc.unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define i32 @loop_live_dead_unseen(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @escape
; CHECK-NOT: dead:
; CHECK-NOT: alloc.unwind:
; CHECK-NOT: load atomic
; CHECK-NOT: store atomic
; CHECK-NOT: poison
; CHECK: ret i32 71

!java-method-compilation = !{}
