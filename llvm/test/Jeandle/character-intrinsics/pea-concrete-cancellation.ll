; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/symbolic-holder.cblog -verify-each %s | FileCheck %s
;
; Rejection of the destination must retry analysis from original IR. A scalar
; alias of the conversion result stored in another object must refer to the
; retained operation, rather than a speculative second read of mutable src.
; CHECK-LABEL: @cancel_alias(
; CHECK-NOT: pea.copy.elem
; CHECK-NOT: string.prefix
; CHECK: %r = call hotspotcc i32 @jeandle.encode_array
; CHECK: store atomic i32 %r,
; CHECK-NOT: pea.copy.elem
; CHECK: ret i32

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare hotspotcc void @jeandle.safepoint_poll()
declare i32 @personality(...)
@state=global i32 0
@pub=global ptr addrspace(1) null
define i32 @cancel_alias(ptr addrspace(1) %src, i1 %first, i1 %repeat) gc "hotspotgc" personality ptr @personality {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) to label %alloc unwind label %u
alloc:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 24, i1 false) to label %work unwind label %u
work:
  %hp=getelementptr i8, ptr addrspace(1) %holder, i64 16
  %r=call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 1, i1 false, i1 false)
  store atomic i32 %r, ptr addrspace(1) %hp unordered, align 4
  store atomic ptr addrspace(1) %holder, ptr @pub unordered, align 8
  br i1 %first, label %left, label %right
left:
  store atomic i32 1, ptr @state seq_cst, align 4
  br label %right
right:
  store atomic i32 2, ptr @state seq_cst, align 4
  br i1 %repeat, label %back, label %out
back:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 104, i32 104, i64 12, ptr addrspace(1) %dst) ]
  br label %left
out:
  %v=load atomic i32, ptr addrspace(1) %hp unordered, align 4
  %same=icmp eq i32 %v, %r
  %ret=zext i1 %same to i32
  ret i32 %ret
u:
  %lp=landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
