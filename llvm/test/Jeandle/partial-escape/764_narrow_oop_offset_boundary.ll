; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; AS1 and AS3 are different numeric representations of an oop.  The shared
; pointer walker may preserve an offset accumulated outside an AS3 round-trip
; in the outer AS1 coordinate system, but it must not reinterpret a GEP inside
; the AS3 representation as the same Java-heap byte offset.

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; The field GEP is outside the encode/decode pair and is expressed in AS1.
; It remains a normal offset-16 access and the object can stay virtual.
define i32 @outer_wide_offset_remains_resolvable()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 76301 to ptr), i32 32, i1 false)
       to label %normal unwind label %unwind
normal:
  %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  %wide = addrspacecast ptr addrspace(3) %narrow to ptr addrspace(1)
  %slot = getelementptr i8, ptr addrspace(1) %wide, i64 16
  store atomic i32 41, ptr addrspace(1) %slot unordered, align 4
  %value = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %value
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @outer_wide_offset_remains_resolvable
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: ret i32 41

; The AS3 GEP changes the compressed representation by one. Its decoded
; Java-heap delta depends on the VM compressed-oop shift (normally eight bytes
; for shift=3), so PEA must not record it as a one-byte field offset. Offset
; resolution fails, the object materializes at the store, and the original
; address calculation/store survive.
define void @inner_narrow_offset_is_unresolved()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
          ptr inttoptr (i64 76302 to ptr), i32 40, i1 false)
       to label %normal unwind label %unwind
normal:
  %narrow = addrspacecast ptr addrspace(1) %o to ptr addrspace(3)
  %narrow.offset = getelementptr i8, ptr addrspace(3) %narrow, i64 1
  %wide = addrspacecast ptr addrspace(3) %narrow.offset to ptr addrspace(1)
  %slot = getelementptr i8, ptr addrspace(1) %wide, i64 16
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @inner_narrow_offset_is_unresolved
; CHECK: %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: %narrow.offset = getelementptr i8, ptr addrspace(3) %narrow, i64 1
; CHECK: %wide = addrspacecast ptr addrspace(3) %narrow.offset to ptr addrspace(1)
; CHECK: %slot = getelementptr i8, ptr addrspace(1) %wide, i64 16
; CHECK: store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
; CHECK: call void @sink(ptr addrspace(1) %o)

!java-method-compilation = !{}
