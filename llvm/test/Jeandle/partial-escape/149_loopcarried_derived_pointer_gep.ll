; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; A DERIVED pointer (a GEP of a loop-body alloc) carried across the back-edge by
; a header PHI. Here %sf = getelementptr %X, 8 is the carried value.
;
; Under the reuse-OrigAlloc model the original body alloc %X is KEPT (it
; dominates the loop body and the latch), so the body GEP %sf of %X stays valid
; and the carried PHI's back-edge incoming stays %sf -- no re-derivation is
; needed. The tracked field store is replayed onto %X at the back-edge
; (latch); the exit @sink receives the carried derived pointer. No poison.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_149_carried_gep(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch ]
  %psf = phi ptr addrspace(1) [ null, %entry ], [ %sf, %latch ]
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
  %ec = icmp eq ptr addrspace(1) %psf, null
  br i1 %ec, label %done, label %obs
obs:
  call void @sink(ptr addrspace(1) %psf)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The carried PHI's back-edge incoming stays the original body GEP %sf (the body
; alloc %X is retained, so %sf stays valid). The body GEP is kept and the
; tracked field store is replayed onto %X at the latch.
; CHECK-LABEL: define void @test_149_carried_gep
; CHECK: %psf = phi ptr addrspace(1) [ null, %entry ], [ %sf, %latch ]
; CHECK: %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; CHECK: %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; CHECK: store atomic i32 %i, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %psf)
; CHECK-NOT: poison

!java-method-compilation = !{}
