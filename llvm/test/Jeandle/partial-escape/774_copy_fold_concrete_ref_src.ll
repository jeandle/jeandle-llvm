; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/774_copy_fold_concrete_ref_src.cblog %s | FileCheck %s --check-prefixes=COMMON,NARROW
; RUN: sed -e 's/@VMOptions.UseCompressedOops = constant i1 true/@VMOptions.UseCompressedOops = constant i1 false/' -e 's/@arrayOopDesc.element_size.object = constant i32 4/@arrayOopDesc.element_size.object = constant i32 8/' %s | opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/774_copy_fold_concrete_ref_src.cblog | FileCheck %s --check-prefixes=COMMON,WIDE

; Concrete-to-virtual fold over a REFERENCE array (identical source and
; destination klasses), in both oop representations:
;   NARROW (compressed): element loads read narrow oops (addrspace 3) and an
;   addrspacecast restores the AS1 semantic field representation.
;   WIDE (uncompressed): element loads read wide oops (addrspace 1) directly.
; Only element 0 is consumed so the element offsets do not depend on the
; representation.

target datalayout = "e-p:64:64-p3:32:32"

@VMOptions.UseCompressedOops = constant i1 true
@arrayOopDesc.element_size.object = constant i32 4

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @copy_fold_concrete_ref(ptr addrspace(1) "java-klass"="22222" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 22222 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false)
         to label %do_copy unwind label %u
do_copy:
  invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 2,
                            ptr null, ptr null, i64 2, i64 2)
      #0 [ "deopt"(i32 99, i32 99, i64 12, ptr addrspace(1) null) ]
      to label %read unwind label %u
read:
  %db = getelementptr inbounds i8, ptr addrspace(1) %dest, i32 16
  %v0 = load atomic ptr addrspace(3), ptr addrspace(1) %db unordered, align 4
  %w0 = addrspacecast ptr addrspace(3) %v0 to ptr addrspace(1)
  ret ptr addrspace(1) %w0
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }

; COMMON-LABEL: define ptr addrspace(1) @copy_fold_concrete_ref
; COMMON-NOT: jeandle.new_array
; COMMON-NOT: jeandle.copy
; The destination load folded to the first copied element.
; COMMON: %[[A0:.*]] = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
; NARROW: %[[L0:.*]] = load atomic ptr addrspace(3), ptr addrspace(1) %[[A0]] unordered, align 4
; NARROW: addrspacecast ptr addrspace(3) %[[L0]] to ptr addrspace(1)
; WIDE: load atomic ptr addrspace(1), ptr addrspace(1) %[[A0]] unordered, align 8
; COMMON: ret ptr addrspace(1)

!java-method-compilation = !{}
