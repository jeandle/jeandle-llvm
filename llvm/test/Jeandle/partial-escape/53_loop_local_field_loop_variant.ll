; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: a loop body allocates an object, stores into one field a value
; computed from the loop counter (i.e. defined AFTER the alloc, inside the
; alloc's normal-dest block), then escapes via @sink. Under reuse-OrigAlloc the
; computed value only needs to dominate its replay point, not the allocation
; site. The source invoke remains and the loop-variant value is replayed before
; the sink.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_loop_loop_variant_escape(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %loop
loop:
  %i = phi i32 [ 0, %entry ], [ %i1, %cont ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %st unwind label %u
st:
  %comp = mul i32 %i, 3
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %comp, ptr addrspace(1) %s unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %cont
cont:
  %i1 = add i32 %i, 1
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; OrigAlloc is the sole allocation; the loop-variant store and sink use it.
; CHECK-LABEL: define void @test_loop_loop_variant_escape
; CHECK: %o = invoke hotspotcc{{.*}}@jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 %comp
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
