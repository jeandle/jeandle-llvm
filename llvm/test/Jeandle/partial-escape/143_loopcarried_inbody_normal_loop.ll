; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; A loop-LOCAL object %X allocated in the body is carried across the back-edge
; by the header pointer-PHI %px and escapes at the loop exit (@sink). The field
; stored is a live SSA value (%i).
;
; Under the reuse-OrigAlloc model the original body alloc %X is KEPT (it
; dominates the back-edge latch and the loop exit). The tracked field store
; is replayed onto %X at the back-edge (the latch), and the carried PHI's
; back-edge incoming stays %X.
; The exit @sink receives the carried pointer directly. No poison.
;
; The header has a single forward predecessor (entry), so this exercises the
; fixpoint path's post-body merge directly (no loop-simplify needed).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_143_inbody_carried(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch ]
  %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %bcont unwind label %u
bcont:
  %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store atomic i32 %i, ptr addrspace(1) %sf unordered, align 4
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  %ec = icmp eq ptr addrspace(1) %px, null
  br i1 %ec, label %done, label %obs
obs:
  call void @sink(ptr addrspace(1) %px)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The original body alloc is RETAINED; the carried PHI's back-edge incoming
; stays %X, and the tracked field store is replayed onto %X at the back-edge
; (latch). No poison anywhere.
; CHECK-LABEL: define void @test_143_inbody_carried
; CHECK: %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %latch ]
; CHECK: %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; CHECK: store atomic i32 %i, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %px)
; CHECK-NOT: poison

!java-method-compilation = !{}
