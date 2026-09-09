; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/450_get_class_folded.cblog \
; RUN:   %s | FileCheck %s

; A surviving getClass fold produces a GC-safe oop-handle load at transform
; time.  Its deopt use is dependency-free with respect to the virtual receiver:
; the final obligation must stop at OopHandleId instead of walking the original
; call argument and retaining the allocation.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1)
    @jeandle.get_class(ptr addrspace(1))
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @getclass_deopt_terminal()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 7 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind

body:
  %class = call hotspotcc ptr addrspace(1)
      @jeandle.get_class(ptr addrspace(1) %o)
  call void @safepoint()
      [ "deopt"(i32 99, i32 99, i64 12,
                  ptr addrspace(1) %class) ]
  ret void

unwind:
  %ex = landingpad i64 cleanup
  resume i64 %ex
}

; CHECK-LABEL: define void @getclass_deopt_terminal()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: jeandle.get_class
; CHECK: %[[CLASS:[A-Za-z0-9._]+]] = load ptr addrspace(1), ptr @oop_handle_
; CHECK: call void @safepoint()
; CHECK-SAME: ptr addrspace(1) %[[CLASS]]
; CHECK-NOT: poison

!java-method-compilation = !{}
