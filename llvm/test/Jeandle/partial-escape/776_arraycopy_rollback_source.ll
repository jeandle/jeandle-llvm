; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/776_arraycopy_rollback_source.cblog \
; RUN:   %s | FileCheck %s

; The arraycopy initially folds while both arrays are virtual. A later
; value-based-class check makes %dest ineligible, so the destination-owned
; ReplaceCall effect is dropped and the real arraycopy survives. %src escapes
; only after the copy: merely replaying its tracked store at @sink would be too
; late. The eligibility dependency must force a fresh retry with %src kept real,
; leaving its original store before the surviving arraycopy.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64) #0
declare hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1))
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @arraycopy_rollback_source()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 1, i32 32, i32 16, i32 1048576)
         to label %new.dest unwind label %unwind

new.dest:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12346 to ptr), i32 1, i32 32, i32 16, i32 1048576)
         to label %copy unwind label %unwind

copy:
  %src.base = getelementptr inbounds i8, ptr addrspace(1) %src, i32 16
  %src.elem = getelementptr inbounds i32, ptr addrspace(1) %src.base, i64 0
  store atomic i32 42, ptr addrspace(1) %src.elem unordered, align 4
  invoke hotspotcc void @jeandle.arraycopy(
            ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 1,
            ptr null, ptr null, i64 1, i64 1)
         to label %after.copy unwind label %unwind

after.copy:
  %is.value.based = call hotspotcc i1
      @jeandle.check_if_value_based(ptr addrspace(1) %dest)
  call void @sink(ptr addrspace(1) %src)
  %dest.base = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %dest.elem = getelementptr inbounds i32, ptr addrspace(1) %dest.base, i64 0
  %value = load atomic i32, ptr addrspace(1) %dest.elem unordered, align 4
  ret i32 %value

unwind:
  %exception = landingpad i64 cleanup
  resume i64 %exception
}

attributes #0 = {
  "jeandle.arraycopy.kind"="arraycopy"
  "jeandle.arraycopy.validated"
}

; CHECK-LABEL: define i32 @arraycopy_rollback_source(
; CHECK: %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i32 42
; CHECK-NEXT: invoke hotspotcc void @jeandle.arraycopy
; CHECK: call hotspotcc i1 @jeandle.check_if_value_based
; CHECK: call void @sink(ptr addrspace(1) %src)
; CHECK: load atomic i32
; CHECK-NOT: pea.matslot

!java-method-compilation = !{}
