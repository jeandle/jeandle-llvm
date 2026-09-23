; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/774_arraycopy_conservative.cblog %s | FileCheck %s

; Conservative paths. None of these folds:
;  - non-constant length (a function argument),
;  - unvalidated call site (no "jeandle.arraycopy.validated" attribute),
;  - zero-length validated copy DOES fold: the call is deleted and no field
;    state changes; a preexisting destination value survives the copy.
; In every non-folding case the pseudo call survives and both virtual arrays
; materialize AT the call (the arrays stay real; tracked stores are replayed
; before the call so the runtime copy sees initialized memory).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0

declare i32 @__gxx_personality_v0(...)

define void @test_arraycopy_nonconst_length(i64 %len) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n1 unwind label %u1
n1:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12346 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %n2 unwind label %u1
n2:
  %sbase = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %s0 = getelementptr inbounds i32, ptr addrspace(1) %sbase, i64 0
  store atomic i32 100, ptr addrspace(1) %s0 unordered, align 4
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 %len,
            ptr null, ptr null, i64 4, i64 4) #1
         to label %ac unwind label %u1
ac:
  ret void
u1:
  %lp1 = landingpad i64 cleanup
  resume i64 %lp1
}

define void @test_arraycopy_unvalidated() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12347 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %m1 unwind label %u2
m1:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12348 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %m2 unwind label %u2
m2:
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
            ptr null, ptr null, i64 4, i64 4)
         to label %mc unwind label %u2
mc:
  ret void
u2:
  %lp2 = landingpad i64 cleanup
  resume i64 %lp2
}

define i32 @test_arraycopy_zero_length() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12349 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %k1 unwind label %u3
k1:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12350 to ptr), i32 4, i32 32, i32 16, i32 1048576)
         to label %k2 unwind label %u3
k2:
  %dbase = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %d0 = getelementptr inbounds i32, ptr addrspace(1) %dbase, i64 0
  store atomic i32 7, ptr addrspace(1) %d0 unordered, align 4
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 0,
            ptr null, ptr null, i64 4, i64 4) #1
         to label %kc unwind label %u3
kc:
  %v0 = load atomic i32, ptr addrspace(1) %d0 unordered, align 4
  ret i32 %v0
u3:
  %lp3 = landingpad i64 cleanup
  resume i64 %lp3
}

attributes #0 = { "jeandle.arraycopy.kind"="arraycopy" }
attributes #1 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.validated" }

; Non-constant length: no fold — the call survives, both arrays materialize
; at the call, and the tracked source store is replayed before it.
; CHECK-LABEL: define void @test_arraycopy_nonconst_length
; CHECK: store atomic i32 100
; CHECK: invoke hotspotcc void @jeandle.arraycopy

; Unvalidated: no fold — the call survives with both arrays kept real.
; CHECK-LABEL: define void @test_arraycopy_unvalidated
; CHECK: invoke hotspotcc void @jeandle.arraycopy

; Zero-length validated: the call folds to nothing and the destination's
; preexisting value is untouched.
; CHECK-LABEL: define i32 @test_arraycopy_zero_length
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: jeandle.arraycopy
; CHECK: ret i32 7
!java-method-compilation = !{}
