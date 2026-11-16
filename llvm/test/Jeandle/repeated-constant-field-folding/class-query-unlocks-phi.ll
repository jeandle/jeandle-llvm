; RUN: opt -S -verify-each -passes=repeated-constant-field-folding -jeandle-vm-callback-log=%S/Inputs/class-query-unlocks-phi.cblog %s | FileCheck %s

@oop_handle_Class_0 = external global ptr addrspace(1)
@oop_handle_Other_1 = external global ptr addrspace(1)
declare hotspotcc i32 @jeandle.klass_access_flags(ptr, i32)
declare hotspotcc i32 @jeandle.klass_modifiers(ptr)
declare hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1))

; The first query removes one arm; the next folding iteration can then prove
; which mirror reaches the downstream modifier query.
; CHECK-LABEL: @query_unlocks_phi(
; CHECK-NOT: call
; CHECK-NOT: phi
; CHECK: ret i32 17
define i32 @query_unlocks_phi() {
entry:
  %flags = call hotspotcc i32 @jeandle.klass_access_flags(ptr inttoptr (i64 123 to ptr), i32 512)
  %interface = icmp ne i32 %flags, 0
  br i1 %interface, label %left, label %right
left:
  %a = load ptr addrspace(1), ptr @oop_handle_Other_1
  br label %join
right:
  %b = load ptr addrspace(1), ptr @oop_handle_Class_0
  br label %join
join:
  %mirror = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %klass = call hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) %mirror)
  %modifiers = call hotspotcc i32 @jeandle.klass_modifiers(ptr %klass)
  ret i32 %modifiers
}

!java-method-compilation = !{}
