; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s
;
; TRUE self-loop: the header is its OWN back-edge predecessor (br back to
; itself). Because a Jeandle alloc is normally an invoke (whose normal dest is
; a different block, so the back-edge pred is that block, not the header), we
; use a call-form allocation here so the alloc lives inside the self-loop header
; itself. This is legal LLVM IR and exercises the hardest timing case for the
; fix: BlockExits[header] is not populated until AFTER processBlock(header),
; so only the post-body merge can resolve the carried PHI's back-edge slot.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_145_selfloop(i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %entry ], [ %i1, %hdr ]
  %px = phi ptr addrspace(1) [ null, %entry ], [ %X, %hdr ]
  %X = call hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
  %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  store atomic i32 %i, ptr addrspace(1) %sf unordered, align 4
  %i1 = add i32 %i, 1
  %c = icmp slt i32 %i, %n
  br i1 %c, label %hdr, label %exit
exit:
  %ec = icmp eq ptr addrspace(1) %px, null
  br i1 %ec, label %done, label %obs
obs:
  call void @sink(ptr addrspace(1) %px)
  br label %done
done:
  ret void
}

; CHECK-LABEL: define void @test_145_selfloop
; CHECK: call void @sink(ptr addrspace(1) %px)
; CHECK-NOT: poison

!java-method-compilation = !{}
