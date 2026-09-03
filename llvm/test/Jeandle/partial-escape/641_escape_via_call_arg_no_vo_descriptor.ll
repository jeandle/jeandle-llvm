; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Negative case for GC-liveness: a reference field holding a NON-NULL CONSTANT
; oop is NOT describable. A constant oop (here inttoptr constants, standing in
; for a ConstantFieldFolding result such as a bitcast of an oop_handle global)
; would be recorded by the stackmap as a constant and trip fill_one_scope_value's
; ShouldNotReachHere on the HotSpot side. planFields therefore bails such a
; field (Cell::Bad), making %o wholly undescribable. %o additionally escapes by
; being passed to @sink, so it is PartiallyEscapes: under reuse-OrigAlloc the
; allocation is KEPT, its field stores are replayed onto it before the escape,
; and the deopt bundle operand stays as the live OrigAlloc reference (no VO
; descriptor). Contrast 388 (scalar fields, described) and 649/650 (wide-oop
; non-constant fields, described).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @escape_via_call_arg() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 24, i1 false)
       to label %n unwind label %u
n:
  %s1 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %s2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 16
  ; Non-null CONSTANT oop field values (not locations): not describable.
  store atomic ptr addrspace(1) inttoptr (i64 555 to ptr addrspace(1)),
      ptr addrspace(1) %s1 unordered, align 8
  store atomic ptr addrspace(1) inttoptr (i64 666 to ptr addrspace(1)),
      ptr addrspace(1) %s2 unordered, align 8
  ; %o is passed to @sink AS A CALL ARGUMENT (escape) and is also in the deopt
  ; bundle. The constant-oop field bail leaves it undescribed; the escape keeps
  ; OrigAlloc, so the deopt operand stays OrigAlloc.
  call void @sink(ptr addrspace(1) %o)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @escape_via_call_arg
; The original allocation invoke is RETAINED (the object escapes via @sink, so
; it is PartiallyEscapes and OrigAlloc is kept; no new invoke is introduced).
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: pea.mat = invoke
; Tracked field stores are replayed onto OrigAlloc before the escape.
; CHECK: store atomic ptr addrspace(1) inttoptr (i64 555 to ptr addrspace(1)),
; CHECK-SAME: ptr addrspace(1) %pea.matslot unordered, align 8
; CHECK: store atomic ptr addrspace(1) inttoptr (i64 666 to ptr addrspace(1)),
; CHECK-SAME: ptr addrspace(1) %pea.matslot{{[0-9]*}} unordered, align 8
; The surviving sink call passes OrigAlloc directly, and its deopt bundle
; operand stays as the LIVE OrigAlloc reference.
; CHECK: call void @sink(ptr addrspace(1) %o)
; CHECK-SAME: [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %o) ]
; NO VO descriptor (ScalarValueType header 262156 / VORefType 524300) is
; emitted: the constant-oop field bail makes %o undescribable.
; CHECK-NOT: i64 262156
; CHECK-NOT: i64 524300

!java-method-compilation = !{}
