; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/805_copy_fold_guarded_source.cblog %s | FileCheck %s

; CHECK-LABEL: define i32 @context_source(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK: load atomic i32

target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)
define i32 @context_source(ptr addrspace(1) nonnull "java-klass"="1000" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %check = call i1 @jeandle.check_instanceof(ptr inttoptr(i64 12345 to ptr), ptr addrspace(1) %src)
 br i1 %check, label %alloc, label %fail
alloc:
 %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr(i64 12345 to ptr), i32 2, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %copy unwind label %u
copy:
 %redundant = call i1 @jeandle.check_instanceof(ptr inttoptr(i64 12345 to ptr), ptr addrspace(1) %src)
 invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dst, i64 0, i64 2, ptr null, ptr null, i64 2, i64 2) #0 to label %read unwind label %u
read:
 %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
 %v = load atomic i32, ptr addrspace(1) %dp unordered, align 4
 %proof = zext i1 %redundant to i32
 %result = add i32 %v, %proof
 ret i32 %result
fail:
 ret i32 -1
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
