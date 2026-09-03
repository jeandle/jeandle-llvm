; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; A virtual object passed to a terminator invoke is materialized before the
; invoke. The opaque callee may mutate the real object before returning or
; unwinding, so neither successor may reuse the pre-invoke virtual field state.
; An object that is not exposed to the callee remains virtual on the unwind
; edge and retains its independently tracked field state.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @mutate_and_maybe_throw(ptr addrspace(1), i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_call_arg_unwind(i1 %take.normal)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %body unwind label %alloc.unwind
body:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  store atomic i32 1, ptr addrspace(1) %slot unordered, align 4
  invoke void @mutate_and_maybe_throw(ptr addrspace(1) %o, i1 %take.normal)
       to label %normal unwind label %handler
normal:
  %normal.value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %normal.value
handler:
  %lp = landingpad i64 cleanup
  %handler.value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %handler.value
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; Both paths after the opaque invoke read the materialized object from memory.
; CHECK-LABEL: define i32 @test_call_arg_unwind(
; CHECK: normal:
; CHECK: %[[NORMAL:[-A-Za-z$._0-9]+]] = load atomic i32, ptr addrspace(1) %slot unordered, align 4
; CHECK: ret i32 %[[NORMAL]]
; CHECK: handler:
; CHECK: landingpad i64
; CHECK-NOT: ret i32 1
; CHECK: %[[HANDLER:[-A-Za-z$._0-9]+]] = load atomic i32, ptr addrspace(1) %slot unordered, align 4
; CHECK: ret i32 %[[HANDLER]]

define i32 @test_unrelated_virtual_unwind(i1 %take.normal)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %passed = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 11111 to ptr), i32 24, i1 false)
       to label %allocate.local unwind label %alloc.unwind
allocate.local:
  %local = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 22222 to ptr), i32 24, i1 false)
       to label %body unwind label %alloc.unwind
body:
  %local.slot = getelementptr inbounds i8, ptr addrspace(1) %local, i64 16
  store atomic i32 7, ptr addrspace(1) %local.slot unordered, align 4
  invoke void @mutate_and_maybe_throw(ptr addrspace(1) %passed, i1 %take.normal)
       to label %normal unwind label %handler
normal:
  ret i32 0
handler:
  %lp = landingpad i64 cleanup
  %local.value = load atomic i32, ptr addrspace(1) %local.slot unordered, align 4
  ret i32 %local.value
alloc.unwind:
  %alloc.lp = landingpad i64 cleanup
  resume i64 %alloc.lp
}

; The unrelated object remains virtual and its handler load still folds.
; CHECK-LABEL: define i32 @test_unrelated_virtual_unwind(
; CHECK-NOT: jeandle.new_instance(ptr inttoptr (i64 22222 to ptr), i32 24)
; CHECK: handler:
; CHECK: ret i32 7
; CHECK-NOT: poison

!java-method-compilation = !{}
