; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; TWO header PHIs each carry a different DERIVED pointer of the same loop-body
; object: %sf1 = gep %X, 8 and %sf2 = gep %X, 16. Under the reuse-OrigAlloc
; model the body alloc %X is retained, so both body GEPs stay valid and each
; carried PHI keeps its original incoming. Both tracked field stores are
; replayed onto %X at their own byte offset at the latch.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_152_carried_multiple(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %latch ]
  %psf1 = phi ptr addrspace(1) [ null, %entry ], [ %sf1, %latch ]
  %psf2 = phi ptr addrspace(1) [ null, %entry ], [ %sf2, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 32, i1 false)
          to label %bcont unwind label %u
bcont:
  %sf1 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  %sf2 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 16
  store atomic i32 %i, ptr addrspace(1) %sf1 unordered, align 4
  store atomic i32 %i, ptr addrspace(1) %sf2 unordered, align 4
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  %ec = icmp eq ptr addrspace(1) %psf1, null
  br i1 %ec, label %done, label %obs
obs:
  call void @sink(ptr addrspace(1) %psf1)
  call void @sink(ptr addrspace(1) %psf2)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_152_carried_multiple
; Both carrying PHIs keep their original body-GEP incomings.
; CHECK: %psf1 = phi ptr addrspace(1) [ null, %entry ], [ %sf1, %latch ]
; CHECK: %psf2 = phi ptr addrspace(1) [ null, %entry ], [ %sf2, %latch ]
; CHECK: %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; Both tracked field stores are replayed onto %X at offsets 8 and 16.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
; CHECK: store atomic i32 %i, ptr addrspace(1) %pea.matslot unordered, align 4
; CHECK: %pea.matslot1 = getelementptr inbounds i8, ptr addrspace(1) %X, i64 16
; CHECK: store atomic i32 %i, ptr addrspace(1) %pea.matslot1 unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %psf1)
; CHECK: call void @sink(ptr addrspace(1) %psf2)
; CHECK-NOT: poison

!java-method-compilation = !{}
