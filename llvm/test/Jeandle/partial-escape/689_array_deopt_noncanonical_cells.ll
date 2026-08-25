; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/689_array_deopt_noncanonical_cells.cblog \
; RUN:   %s | FileCheck %s
; RUN: opt -S -verify-each \
; RUN:   -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -jeandle-vm-callback-log=%S/Inputs/689_array_deopt_noncanonical_cells.cblog \
; RUN:   %s | FileCheck %s --check-prefix=CYCLE

; A virtual-array descriptor represents exactly one canonical cell per Java
; element.  Any touched byte cell that cannot be mapped to
; base + index*scale with the array's element storage representation must
; reject the whole descriptor.  boolean[] uses i8 physical storage for its i1
; logical element type; all other kinds require the exact element type.  The
; fallback reuses the original allocation, replays the tracked store before the
; safepoint, and leaves the real oop in the bundle.

@arrayOopDesc.element_size.object = private constant i32 8
@arrayOopDesc.element_size.long = private constant i32 4

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @safepoint()
declare i32 @__gxx_personality_v0(...)

define void @noncanonical_byte_cell() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68901 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %partial = getelementptr inbounds i8, ptr addrspace(1) %base, i64 1
  store atomic i8 7, ptr addrspace(1) %partial unordered, align 1
  call void @safepoint()
      [ "deopt"(i32 1, i32 1, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @noncanonical_byte_cell(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 17
; CHECK-NEXT: store atomic i8 7, ptr addrspace(1) %[[SLOT]] unordered, align 1
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 1, i32 1, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

define void @partial_canonical_cell() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68902 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  store atomic i16 4660, ptr addrspace(1) %base unordered, align 2
  call void @safepoint()
      [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @partial_canonical_cell(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK-NEXT: store atomic i16 4660, ptr addrspace(1) %[[SLOT]] unordered, align 2
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 2, i32 2, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

define void @wrong_kind_same_width() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68903 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  store atomic float 1.500000e+00, ptr addrspace(1) %base unordered, align 4
  call void @safepoint()
      [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @wrong_kind_same_width(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK-NEXT: store atomic float 1.500000e+00, ptr addrspace(1) %[[SLOT]] unordered, align 4
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 3, i32 3, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

define void @zero_offset_wrappers_are_canonical() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68904 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %identity = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 0
  %frozen = freeze ptr addrspace(1) %identity
  %base = getelementptr inbounds i8, ptr addrspace(1) %frozen, i64 16
  %cell = getelementptr inbounds i32, ptr addrspace(1) %base, i64 1
  store atomic i32 99, ptr addrspace(1) %cell unordered, align 4
  call void @safepoint()
      [ "deopt"(i32 4, i32 4, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @zero_offset_wrappers_are_canonical(
; CHECK-NOT: @jeandle.new_array
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 4, i32 4,
; CHECK-SAME: i64 262157, i64 68904, i32 2,
; CHECK-SAME: i64 68719476746, i32 0,
; CHECK-SAME: i64 85899345930, i32 99,
; CHECK-SAME: i64 524300, i32 0) ]

; A boolean[] has one-byte physical cells even though its logical LLVM element
; type is i1.  The front end therefore uses i8 loads and stores.  That exact
; storage representation is canonical for a VM boolean element and must remain
; eligible for a deopt descriptor.
define void @boolean_i8_cells_are_canonical() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68913 to ptr), i32 3, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  store atomic i8 1, ptr addrspace(1) %base unordered, align 1
  %last = getelementptr inbounds i8, ptr addrspace(1) %base, i64 2
  store atomic i8 1, ptr addrspace(1) %last unordered, align 1
  call void @safepoint()
      [ "deopt"(i32 14, i32 14, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @boolean_i8_cells_are_canonical(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: store atomic
; CHECK: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 14, i32 14,
; CHECK-SAME: i64 262157, i64 68913, i32 3,
; CHECK-SAME: i64 68719476746, i8 1,
; CHECK-SAME: i64 73014444042, i1 false,
; CHECK-SAME: i64 77309411338, i8 1,
; CHECK-SAME: i64 524300, i32 0) ]

define void @symbolic_offset_materializes_before_deopt(i64 %index)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68905 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %cell = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %index
  store atomic i32 77, ptr addrspace(1) %cell unordered, align 4
  call void @safepoint()
      [ "deopt"(i32 5, i32 5, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @symbolic_offset_materializes_before_deopt(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: store atomic i32 77, ptr addrspace(1) %cell unordered, align 4
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 5, i32 5, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

; A typed GEP's LLVM stride is part of its address.  The deliberately
; inconsistent long layout below has VM scale 4 but LLVM i64 stride 8.
; Rejecting the typed matcher must preserve the original index-1 address at
; byte offset 24 rather than virtualizing/replaying it at VM offset 20.
define void @typed_stride_mismatch_materializes() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68912 to ptr), i32 2, i32 24, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  %cell = getelementptr inbounds i64, ptr addrspace(1) %base, i64 1
  store atomic i64 123, ptr addrspace(1) %cell unordered, align 8
  call void @safepoint()
      [ "deopt"(i32 12, i32 12, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @typed_stride_mismatch_materializes(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK-NEXT: %cell = getelementptr inbounds i64, ptr addrspace(1) %base, i64 1
; CHECK-NEXT: store atomic i64 123, ptr addrspace(1) %cell unordered, align 8
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 12, i32 12, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

; Descriptor planning independently validates the touched store's complete
; byte range.  This canonical byte address records an i64 cell at offset 16,
; but the 8-byte store cannot fit one 4-byte VM element or the length-1 array.
define void @descriptor_store_size_mismatch_materializes() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68912 to ptr), i32 1, i32 20, i32 16, i32 1048576)
      to label %body unwind label %unwind
body:
  %cell = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
  store atomic i64 456, ptr addrspace(1) %cell unordered, align 8
  call void @safepoint()
      [ "deopt"(i32 13, i32 13, i64 12, ptr addrspace(1) %arr) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @descriptor_store_size_mismatch_materializes(
; CHECK-COUNT-1: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %[[LONG_SLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK-NEXT: store atomic i64 456, ptr addrspace(1) %[[LONG_SLOT]] unordered, align 8
; CHECK-NEXT: call void @safepoint() [ "deopt"(i32 13, i32 13, i64 12, ptr addrspace(1) %arr) ]
; CHECK-NOT: i64 262157
; CHECK-NOT: i64 524300

; A malformed outer and a shared direct-root child form one reconstruction
; component.  Generic fallback for the outer recursively materializes the
; child, so the child must not also receive a deopt descriptor.  A third,
; disconnected root remains describable, proving fallback is component-local
; rather than all-or-nothing for the safepoint.
define void @malformed_outer_shared_direct_child() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68906 to ptr), i32 2, i32 32, i32 16, i32 1048576)
      to label %alloc.child unwind label %unwind
alloc.child:
  %child = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68907 to ptr), i32 16, i1 false)
      to label %alloc.independent unwind label %unwind
alloc.independent:
  %independent = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68911 to ptr), i32 16, i1 false)
      to label %body unwind label %unwind
body:
  %base = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  %element = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %base, i64 1
  store atomic ptr addrspace(1) %child, ptr addrspace(1) %element unordered, align 8
  %bad = getelementptr inbounds i8, ptr addrspace(1) %base, i64 1
  store atomic i8 7, ptr addrspace(1) %bad unordered, align 1
  call void @safepoint()
      [ "deopt"(i32 6, i32 6, i64 12,
                 ptr addrspace(1) %outer,
                 i64 4294967308, ptr addrspace(1) %child,
                 i64 8589934604,
                 ptr addrspace(1) %independent) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @malformed_outer_shared_direct_child(
; CHECK-COUNT-1: inttoptr (i64 68906 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68907 to ptr)
; CHECK-NOT: inttoptr (i64 68911 to ptr)
; CHECK: %[[BAD:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 17
; CHECK-NEXT: store atomic i8 7, ptr addrspace(1) %[[BAD]] unordered, align 1
; CHECK-NEXT: %[[ELEM:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 24
; CHECK-NEXT: store atomic ptr addrspace(1) %child, ptr addrspace(1) %[[ELEM]] unordered, align 8
; CHECK-NEXT: call void @safepoint()
; The independent object is the only descriptor, so dense numbering assigns
; it wire id 0: klass 68911, zero fields.
; CHECK-SAME: [ "deopt"(i32 6, i32 6,
; CHECK-SAME: i64 262156, i64 68911, i32 0,
; CHECK-SAME: i64 12, ptr addrspace(1) %outer,
; CHECK-SAME: i64 4294967308, ptr addrspace(1) %child,
; independent root slot -> VORef wire id 0.
; CHECK-SAME: i64 524300, i32 0) ]
; CHECK-NEXT: ret void

; A malformed root connected to a cycle must make the entire cycle real.
; Otherwise the direct-root node in the cycle is both described and recursively
; materialized while replaying outer[1] = a, a.f = b, b.f = a.
define void @malformed_outer_cyclic_component() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
      ptr inttoptr (i64 68908 to ptr), i32 2, i32 32, i32 16, i32 1048576)
      to label %alloc.a unwind label %unwind
alloc.a:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68909 to ptr), i32 24, i1 false)
      to label %alloc.b unwind label %unwind
alloc.b:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 68910 to ptr), i32 24, i1 false)
      to label %body unwind label %unwind
body:
  %outer.base = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 16
  %outer.element = getelementptr inbounds ptr addrspace(1), ptr addrspace(1) %outer.base, i64 1
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %outer.element unordered, align 8
  %a.slot = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %a.slot unordered, align 8
  %b.slot = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %b.slot unordered, align 8
  %bad = getelementptr inbounds i8, ptr addrspace(1) %outer.base, i64 1
  store atomic i8 9, ptr addrspace(1) %bad unordered, align 1
  call void @safepoint()
      [ "deopt"(i32 7, i32 7, i64 12,
                 ptr addrspace(1) %outer,
                 i64 4294967308, ptr addrspace(1) %b) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @malformed_outer_cyclic_component(
; CHECK-COUNT-1: inttoptr (i64 68908 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68909 to ptr)
; CHECK-COUNT-1: inttoptr (i64 68910 to ptr)
; CHECK: %[[BSLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %a, ptr addrspace(1) %[[BSLOT]] unordered, align 8
; CHECK: %[[ASLOT:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
; CHECK-NEXT: store atomic ptr addrspace(1) %b, ptr addrspace(1) %[[ASLOT]] unordered, align 8
; CHECK: %[[BAD:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 17
; CHECK-NEXT: store atomic i8 9, ptr addrspace(1) %[[BAD]] unordered, align 1
; CHECK-NEXT: %[[ELEM:[-A-Za-z$._0-9]+]] = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 24
; CHECK-NEXT: store atomic ptr addrspace(1) %a, ptr addrspace(1) %[[ELEM]] unordered, align 8
; CHECK-NEXT: call void @safepoint()
; CHECK-SAME: [ "deopt"(i32 7, i32 7, i64 12,
; CHECK-SAME: ptr addrspace(1) %outer,
; CHECK-SAME: i64 4294967308, ptr addrspace(1) %b) ]
; CHECK-NEXT: ret void

; The transitive-only %a node (ObjectID 1) must not receive a descriptor
; anywhere in the cyclic function or its complete deopt bundle.
; CYCLE-LABEL: define void @malformed_outer_cyclic_component(
; CYCLE-NOT: i64 4295229452
; CYCLE: ret void

!java-method-compilation = !{}
