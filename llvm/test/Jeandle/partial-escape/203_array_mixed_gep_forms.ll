; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/203_array_mixed_gep_forms.cblog %s | FileCheck %s

; int[] virtual where one element is accessed via the i8 + constant
; byte-offset form (resolveFieldOffset's natural path) and a second
; element via the typed-element GEP chain (matchArrayElementGEP path).
; The two forms must agree on the canonical byte offsets so both stores
; and both loads collapse.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_mixed_forms() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; Element 0 — i8 byte-offset form, byte offset = 16.
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  store atomic i32 5, ptr addrspace(1) %p0 unordered, align 4
  ; Element 3 — typed GEP chain.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p3 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 3
  store atomic i32 11, ptr addrspace(1) %p3 unordered, align 4
  ; Loads via the *other* GEP shape from how the matching store was made.
  %p0r = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  %v0 = load atomic i32, ptr addrspace(1) %p0r unordered, align 4
  %p3r = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 28
  %v3 = load atomic i32, ptr addrspace(1) %p3r unordered, align 4
  %r = add i32 %v0, %v3
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_mixed_forms
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %r = add i32 5, 11
; CHECK: ret i32 %r

!java-method-compilation = !{}
