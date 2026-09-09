; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; Nested loops: an OUTER loop contains an INNER loop. A loop-LOCAL object %IX
; allocated in the INNER body is carried across the inner back-edge by the inner
; header PHI %ipx and escapes at the inner loop's exit. The inner loop is
; processed by recursive processLoop, so its OWN post-body merge must handle the
; carried alloc (the outer loop's merge does not see inner-body allocs).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_147_nested(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %ohdr
ohdr:
  %oi = phi i32 [ 0, %entry ], [ %oi1, %olatch ]
  %cc = icmp slt i32 %oi, %n
  br i1 %cc, label %obody, label %oexit
obody:
  br label %ihdr
ihdr:
  %ii = phi i32 [ %oi, %obody ], [ %ii1, %ilatch ]
  %ipx = phi ptr addrspace(1) [ null, %obody ], [ %IX, %ilatch ]
  %ic = icmp slt i32 %ii, %n
  br i1 %ic, label %ibody, label %iexit
ibody:
  %IX = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %ibcont unwind label %u
ibcont:
  %isf = getelementptr inbounds i8, ptr addrspace(1) %IX, i64 8
  store atomic i32 %ii, ptr addrspace(1) %isf unordered, align 4
  br label %ilatch
ilatch:
  %ii1 = add i32 %ii, 1
  br label %ihdr
iexit:
  %iec = icmp eq ptr addrspace(1) %ipx, null
  br i1 %iec, label %olatch, label %iobs
iobs:
  call void @sink(ptr addrspace(1) %ipx)
  br label %olatch
olatch:
  %oi1 = add i32 %oi, 1
  br label %ohdr
oexit:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The inner loop's carried object survives (materialized at the inner back-edge);
; the @sink at the inner exit receives a real pointer; no poison.
; CHECK-LABEL: define void @test_147_nested
; CHECK: call void @sink(ptr addrspace(1) %ipx)
; CHECK-NOT: poison

!java-method-compilation = !{}
