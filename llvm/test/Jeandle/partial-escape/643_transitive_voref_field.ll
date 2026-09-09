; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Transitive VORef field. VO %a (klass 100) has two fields: a scalar at
; offset 8 (int %x) and a REFERENCE at offset 16 whose value is VO %b (klass
; 200, one scalar field at offset 8 = int %y). Both %a and %b are never-
; escaping and virtual at the safepoint. %a is referenced directly from the
; deopt bundle (a locals slot); %b is referenced ONLY via %a's field — it is a
; TRANSITIVE member of the described set.
;
; Both must be described: %a's ref field is a VORef FIELD (encoding ValueTy =
; VORefLocalType, value slot = i32 wire ID of %b), and %b gets its own
; descriptor (referenced by ID from %a's field) with NO bundle slot rewritten
; (its OrigAlloc is not a bundle operand). This mirrors nested virtual-object
; descriptors with ID back-refs. Asserts the transitive closure is complete: no
; VORef to an undescribed VO.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(i32, i32)
declare i32 @__gxx_personality_v0(...)

define void @transitive_voref_field(i32 %x, i32 %y) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 100 to ptr), i32 24, i1 false)
       to label %alloc_b unwind label %u
alloc_b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 200 to ptr), i32 16, i1 false)
       to label %body unwind label %u
body:
  ; a: offset 8 = int %x, offset 16 = ref %b
  %af1 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  %af2 = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %af1 unordered, align 4
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %af2 unordered, align 8
  ; b: offset 8 = int %y
  %bf1 = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 %y, ptr addrspace(1) %bf1 unordered, align 4
  %va = load atomic i32, ptr addrspace(1) %af1 unordered, align 4
  %vb = load atomic i32, ptr addrspace(1) %bf1 unordered, align 4
  ; Only %va/%vb (scalars) reach @sink. %a lives in the deopt bundle (locals
  ; slot, enc(LocalType, index=0, T_OBJECT)=12); %b lives ONLY via %a's field.
  call void @sink(i32 %va, i32 %vb)
       [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) %a) ]
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Check the high-level shape via -jeandle-trace-pea-free reasoning: FileCheck
; the emitted bundle. Canonical root-first pool order assigns wire ID 0 to %a
; and wire ID 1 to its transitive dependency %b.
; CHECK-LABEL: define void @transitive_voref_field
; Both OrigAllocs are eliminated (NeverEscapes).
; CHECK-NOT: jeandle.new_instance
; CHECK: call void @sink(i32 %x, i32 %y)
; CHECK-SAME: [ "deopt"(
; CHECK-SAME: i32 99, i32 99,
; Descriptors are emitted in canonical wire-ID order.
; Descriptor a header (wire ID 0, ScalarValueType, T_OBJECT):
; (0<<32)|(4<<16)|12 = 262156.
; CHECK-SAME: i64 262156, i64 100, i32 2,
; a field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %x
; CHECK-SAME: i64 34359738378, i32 %x,
; a field 1 (offset 16, VORefLocalType/T_OBJECT): (16<<32)|(8<<16)|12 = 68720001036
;   -> value is the i32 wire ID of %b (1)
; CHECK-SAME: i64 68720001036, i32 1,
; Descriptor b header (wire ID 1, ScalarValueType, T_OBJECT):
; (1<<32)|(4<<16)|12 = 4295229452.
; CHECK-SAME: i64 4295229452, i64 200, i32 1,
; b field 0 (offset 8, LocalType/T_INT): (8<<32)|10 = 34359738378 -> value %y
; CHECK-SAME: i64 34359738378, i32 %y,
; the OrigAlloc locals slot for %a is replaced by a VORefLocalType reference
; to wire ID 0: (0<<32)|(8<<16)|12 = 524300, followed by i32 0.
; CHECK-SAME: i64 524300, i32 0) ]
; The eliminated OrigAllocs must not appear in the bundle.
; CHECK-NOT: addrspace(1) %a
; CHECK-NOT: addrspace(1) %b

!java-method-compilation = !{}
