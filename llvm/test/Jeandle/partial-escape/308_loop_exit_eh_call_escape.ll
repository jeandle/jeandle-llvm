; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A loop-local object is passed to an invoke whose unwind destination is a
; catch landingpad. Passing %obj to @may_throw is the actual escape, so PEA
; retains OrigAlloc and both normal/unwind state use that same pointer.
; Exception unwind is not deopt; loop exit adds no materialization beyond
; the escape itself.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @may_throw(ptr addrspace(1))
declare void @catch_handler(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

@C = external addrspace(1) global ptr addrspace(1)

define void @test_loop_exit_eh(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr

hdr:
  %i = phi i32 [0, %entry], [%inext, %latch]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %ret

body:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
                  ptr inttoptr (i64 8888 to ptr), i32 16, i1 false)
              to label %check unwind label %u
check:
  invoke void @may_throw(ptr addrspace(1) %obj)
          to label %latch unwind label %catchlp

latch:
  %inext = add i32 %i, 1
  br label %hdr

ret:
  ret void

catchlp:
  ; The handler observes the same escaped OrigAlloc.
  %lp = landingpad i64
          catch ptr null
  call void @catch_handler(ptr addrspace(1) %obj)
  resume i64 %lp

u:
  ; Allocation failure cleanup.
  %lpc = landingpad i64 cleanup
  resume i64 %lpc
}

; OrigAlloc is the sole allocation and both invoke/handler consumers use it.
; CHECK-LABEL: define void @test_loop_exit_eh
; CHECK: %obj = invoke {{.*}}@jeandle.new_instance({{.*}}i64 8888
; CHECK-NOT: @jeandle.new_instance
; CHECK: invoke void @may_throw(ptr addrspace(1) %obj)
; CHECK: call void @catch_handler(ptr addrspace(1) %obj)

!java-method-compilation = !{}
