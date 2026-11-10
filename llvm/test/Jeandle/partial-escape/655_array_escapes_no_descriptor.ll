; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/655_array_escapes_no_descriptor.cblog %s | FileCheck %s

; NEGATIVE: an int[] that ESCAPES (passed as a real call argument to @escape)
; is materialized and must NOT be described by a VO descriptor at the later
; @sink safepoint. Its OrigAlloc (jeandle.new_array) is kept (PartiallyEscapes
; reuses OrigAlloc), and the deopt bundle retains the original OrigAlloc
; pointer in the locals slot (enc 12 + ptr), neither rewritten to a VORef
; (enc 524300) nor preceded by a T_ARRAY descriptor header (enc 262157).

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @escape(ptr addrspace(1))
declare void @sink(i32)
declare i32 @__gxx_personality_v0(...)

define void @array_escapes_no_descriptor(i32 %x) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 55005 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  ; int[] base 16, scale 4: index 1 @ byte offset 20.
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p1 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  store atomic i32 %x, ptr addrspace(1) %p1 unordered, align 4
  ; %arr escapes here (materialized) — passed as a real call argument.
  call void @escape(ptr addrspace(1) %arr)
  ; Later safepoint: %arr is in the deopt bundle but already materialized, so
  ; it is NOT described — the bundle keeps the real OrigAlloc pointer.
  call void @sink(i32 %x)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %arr) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @array_escapes_no_descriptor
; The array escapes, so jeandle.new_array is kept (OrigAlloc reused).
; CHECK: jeandle.new_array
; No T_ARRAY VO descriptor header (262157) is emitted anywhere.
; CHECK-NOT: i64 262157
; No VORef locals-slot rewrite (524300): the bundle keeps the original slot.
; CHECK-NOT: i64 524300

!java-method-compilation = !{}
