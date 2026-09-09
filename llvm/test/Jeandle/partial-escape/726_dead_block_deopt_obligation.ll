; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   %s | FileCheck %s

; A PEA-folded condition makes %dead.trap unreachable.  The trap has no
; analyzed block state and therefore no virtual-object descriptor, but it also
; has no final deopt obligation: the same committed CFG plan removes it.  The
; live safepoint must retain the virtual root and descriptor without forcing a
; retry that disables virtualization.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @dead_safepoint()
declare void @live_safepoint()
declare i32 @__gxx_personality_v0(...)

define void @dead_block_deopt_has_no_obligation()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 72601 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %is.null = icmp eq ptr addrspace(1) %o, null
  br i1 %is.null, label %dead.trap, label %live

dead.trap:
  call void @dead_safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void

live:
  call void @live_safepoint()
      [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @dead_block_deopt_has_no_obligation()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: dead_safepoint
; CHECK: call void @live_safepoint()
; CHECK-SAME: i64 262156, i64 72601, i32 0
; CHECK-NOT: poison

!java-method-compilation = !{}
