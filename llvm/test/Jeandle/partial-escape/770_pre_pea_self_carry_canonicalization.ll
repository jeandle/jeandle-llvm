; RUN: opt -S -passes="loop-simplify,instcombine" %s | FileCheck %s --check-prefix=CANON
; RUN: opt -S -verify-each -passes="jeandle<O3>" -jeandle-inline=off \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/770_self_carry.cblog \
; RUN:   -jeandle-dump-pea-ir-function=self_carry_field \
; RUN:   -jeandle-dump-pea-ir-function=multi_latch_carry \
; RUN:   -jeandle-dump-pea-stats %s 2>&1 | FileCheck %s --check-prefix=PIPELINE

; Loop canonicalization precedes PEA, including every outer iteration.
; A trivial self-carry folds to its forward value. Multiple backedges with
; an unchanged value on one edge become nested loops with distinct carriers.
; Check both the canonical shapes and scalar replacement in the real pipeline.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))

define void @self_carry_field(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
      to label %prep unwind label %u
prep:
  %s = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 1, ptr addrspace(1) %s unordered, align 4
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %o, %prep ], [ %p, %loop ]
  %i = phi i32 [ 0, %prep ], [ %i1, %loop ]
  %slot = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  store atomic i32 %i, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i, %n
  br i1 %c, label %loop, label %exit
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CANON-LABEL: define void @self_carry_field
; CANON-NOT: phi ptr
; CANON: ret void

; PIPELINE-LABEL: ;; PEA-DUMP before iter=0 function self_carry_field
; PIPELINE: %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; PIPELINE-NOT: phi ptr
; PIPELINE: store atomic i32 %i,
; PIPELINE: ;; PEA stats @self_carry_field: NeverEscapes=1 PartiallyEscapes=0 AlwaysEscapes=0
; PIPELINE-LABEL: ;; PEA-DUMP after iter=0 function self_carry_field
; PIPELINE-NOT: @jeandle.new_instance
; PIPELINE-NOT: store atomic
; PIPELINE-NOT: load atomic
; PIPELINE: call void @use(i32 %i)
; PIPELINE-NOT: store atomic
; PIPELINE-NOT: load atomic
; PIPELINE: ret void

define void @multi_latch_carry(i32 %n, i1 %replace) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
      to label %an unwind label %u
an:
  %sa = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 7, ptr addrspace(1) %sa unordered, align 4
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
      to label %prep unwind label %u
prep:
  %sb = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 9, ptr addrspace(1) %sb unordered, align 4
  br label %loop
loop:
  %p = phi ptr addrspace(1) [ %a, %prep ], [ %b, %rep ], [ %p, %carry ]
  %i = phi i32 [ 0, %prep ], [ %i1, %rep ], [ %i1, %carry ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %p, i64 8
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  call void @use(i32 %v)
  %i1 = add i32 %i, 1
  br i1 %replace, label %rep, label %carry
rep:
  br label %loop
carry:
  br label %loop
exit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CANON-LABEL: define void @multi_latch_carry
; CANON: %p.ph = phi ptr addrspace(1) [ %b, %rep ], [ %a, %prep ]
; CANON-NOT: phi ptr
; CANON: %slot = getelementptr {{.*}}ptr addrspace(1) %p.ph,
; CANON: ret void

; PIPELINE-LABEL: ;; PEA-DUMP before iter=0 function multi_latch_carry
; PIPELINE: %a = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; PIPELINE: %b = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; PIPELINE: %p2.us = phi ptr addrspace(1) [ %b, %body.us ], [ %a, %body.us.preheader ]
; PIPELINE: ;; PEA stats @multi_latch_carry: NeverEscapes=2 PartiallyEscapes=0 AlwaysEscapes=0
; PIPELINE-LABEL: ;; PEA-DUMP after iter=0 function multi_latch_carry
; PIPELINE-NOT: @jeandle.new_instance
; PIPELINE-NOT: store atomic
; PIPELINE-NOT: load atomic
; PIPELINE: ret void

!java-method-compilation = !{}
