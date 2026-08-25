; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; A DERIVED pointer carried across the back-edge where the derivation is a
; bitcast (offset 0): %sf = bitcast %X. Under the reuse-OrigAlloc model the
; body alloc %X is retained, so the body bitcast %sf stays valid and the
; carried PHI's back-edge incoming stays %sf (no materialized base, no extra
; GEP). The tracked field store is replayed onto %X at offset 0 at the latch.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_150_carried_bitcast(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
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
  %sf = bitcast ptr addrspace(1) %X to ptr addrspace(1)
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

; CHECK-LABEL: define void @test_150_carried_bitcast
; The carried PHI's back-edge incoming stays the body bitcast %sf.
; CHECK: %psf = phi ptr addrspace(1) [ null, %entry ], [ %sf, %latch ]
; CHECK: %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; The body bitcast of the retained OrigAlloc is kept.
; CHECK: %sf = bitcast ptr addrspace(1) %X to ptr addrspace(1)
; The tracked field store is replayed onto %X at offset 0 at the back-edge.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %X, i64 0
; CHECK: store atomic i32 %i, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %psf)
; CHECK-NOT: poison

!java-method-compilation = !{}
