; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; EH handler (cleanuppad) that reads a loop-local VO's field.
;
; %o is a loop-local virtual; the loop body's may_throw invoke unwinds to a
; cleanuppad (%cleanup) that READS %o's field. As with the landingpad form
; (430_loop_exit_cleanup_reads_vo.ll), PEA propagates %o's virtual state
; (field = 42) to the cleanuppad via the unwind-edge pre-invoke snapshot, so
; the cleanup's load FOLDS to the stored constant. %o stays NeverEscapes and is
; eliminated; the cleanup calls @use(42).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @may_throw()
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_loop_exit_cleanuppad_reads_vo(i1 %cond) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
  ptr inttoptr (i64 12345 to ptr), i32 32, i1 false)
  to label %body unwind label %oom
body:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %f unordered, align 4
  invoke void @may_throw() to label %back unwind label %cleanup
back:
  br i1 %cond, label %loop, label %exit
exit:
  ret void
oom:
  %lp0 = landingpad i64 cleanup
  resume i64 %lp0
cleanup:
  %cp = cleanuppad within none []
  %fv = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %r = load atomic i32, ptr addrspace(1) %fv unordered, align 4
  call void @use(i32 %r)
  cleanupret from %cp unwind to caller
}

; CHECK-LABEL: define void @test_loop_exit_cleanuppad_reads_vo
; %o is eliminated (NeverEscapes); the cleanup's load folds to the stored
; constant 42 via the unwind-edge virtual-state propagation.
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 42)

!java-method-compilation = !{}
