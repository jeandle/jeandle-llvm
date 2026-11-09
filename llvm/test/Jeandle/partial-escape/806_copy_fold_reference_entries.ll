; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" -jeandle-vm-callback-log=%S/Inputs/806_copy_fold_reference_entries.cblog %s | FileCheck %s

; CHECK-LABEL: define ptr addrspace(1) @narrow_entries(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: ret ptr addrspace(1) %string

target datalayout = "e-p:64:64-p3:32:32"
@VMOptions.UseCompressedOops = constant i1 true
@arrayOopDesc.element_size.object = constant i32 4
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)
define ptr addrspace(1) @narrow_entries(ptr addrspace(1) nonnull "java-klass"="2001" "java-klass-exact" %string) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr(i64 1000 to ptr), i32 1, i32 24, i32 16, i32 1048576) to label %init unwind label %u
init:
 %sp = getelementptr inbounds i8, ptr addrspace(1) %src, i64 16
 %narrow = addrspacecast ptr addrspace(1) %string to ptr addrspace(3)
 store atomic ptr addrspace(3) %narrow, ptr addrspace(1) %sp unordered, align 4
 %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr(i64 2000 to ptr), i32 1, i32 24, i32 16, i32 1048576) to label %copy unwind label %u
copy:
 invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 1, i64 1) #0 to label %read unwind label %u
read:
 %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
 %v = load atomic ptr addrspace(3), ptr addrspace(1) %dp unordered, align 4
 %wide = addrspacecast ptr addrspace(3) %v to ptr addrspace(1)
 ret ptr addrspace(1) %wide
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="arraycopy" }
!java-method-compilation = !{}
