; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Loop without unique preheader (two forward preds into the header),
; but the only alloc is INSIDE the body. The body alloc is loop-local
; (a stored value is read back and the i32 is consumed). The
; bail-on-virtual-at-forward-pred step doesn't touch it (the
; forward-pred BlockExits carry no virtuals — the alloc didn't exist
; pre-loop). The single REGULAR-mode body pass folds the
; store/load/use chain on the loop-local alloc.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_c6_no_preheader_body_alloc(i1 %p, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %p, label %fwd_a, label %fwd_b
fwd_a:
  br label %hdr
fwd_b:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
       to label %bcont unwind label %u
bcont:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %i, ptr addrspace(1) %s unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %s unordered, align 4
  call void @use(i32 %v)
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The body alloc is eliminated; @use receives %i directly.
; CHECK-LABEL: define void @test_c6_no_preheader_body_alloc
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: call void @use(i32 %i)

!java-method-compilation = !{}
