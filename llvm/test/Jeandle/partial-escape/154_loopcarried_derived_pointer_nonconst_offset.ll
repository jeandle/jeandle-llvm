; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; A DERIVED pointer with a VARIABLE (non-constant) GEP index carried across the
; back-edge: %sf = gep %X, %i. A variable-offset access cannot be mapped to a
; tracked field, so the sound fallback applies: the object is marked
; ineligible and stays a real allocation; %sf keeps its real base; no poison.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_154_nonconst(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch ]
  %psf = phi ptr addrspace(1) [ null, %entry ], [ %sf, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 64, i1 false)
          to label %bcont unwind label %u
bcont:
  %idx = zext i32 %i to i64
  %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 %idx
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

; Sound fallback: the original allocation survives (AlwaysEscapes) and %sf
; keeps its real base %X (NOT poison).
; CHECK-LABEL: define void @test_154_nonconst
; CHECK: %X = invoke
; CHECK: %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 %idx
; CHECK: call void @sink(ptr addrspace(1) %psf)
; CHECK-NOT: poison

!java-method-compilation = !{}
