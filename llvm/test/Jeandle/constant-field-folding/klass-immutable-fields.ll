; RUN: opt -S -verify-each -passes="constant-field-folding,instcombine,simplifycfg" -jeandle-vm-callback-log=%S/Inputs/klass-immutable-fields.cblog %s | FileCheck %s
;
; Immutable Klass facts must remove impossible clone guards on complete IR.
; Raw native constants without Klass provenance and unsupported accesses stay real.

target datalayout = "e-p:64:64-p1:64:64"

declare ptr @jeandle.load_klass(ptr addrspace(1))
declare ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

define i1 @clone_fast(ptr addrspace(1) nonnull "java-klass"="123456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %slot = getelementptr i8, ptr %klass, i64 496
  %method = load atomic ptr, ptr %slot unordered, align 8
  %flags.addr = getelementptr i8, ptr %klass, i64 172
  %flags = load atomic i32, ptr %flags.addr unordered, align 4
  %target.ok = icmp eq ptr %method, inttoptr (i64 10000 to ptr)
  %clone.flags = and i32 %flags, -1073741824
  %flags.ok = icmp eq i32 %clone.flags, -2147483648
  %fast = and i1 %target.ok, %flags.ok
  ret i1 %fast
}

; CHECK-LABEL: define i1 @clone_fast(
; CHECK-NEXT: ret i1 true

define i1 @clone_override(ptr addrspace(1) nonnull "java-klass"="223456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %slot = getelementptr i8, ptr %klass, i64 496
  %method = load atomic ptr, ptr %slot unordered, align 8
  %target.ok = icmp eq ptr %method, inttoptr (i64 10000 to ptr)
  ret i1 %target.ok
}

; CHECK-LABEL: define i1 @clone_override(
; CHECK-NEXT: ret i1 false

define i1 @clone_finalizer(ptr addrspace(1) nonnull "java-klass"="323456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %flags.addr = getelementptr i8, ptr %klass, i64 172
  %flags = load atomic i32, ptr %flags.addr unordered, align 4
  %clone.flags = and i32 %flags, -1073741824
  %flags.ok = icmp eq i32 %clone.flags, -2147483648
  ret i1 %flags.ok
}

; CHECK-LABEL: define i1 @clone_finalizer(
; CHECK-NEXT: ret i1 false

define i1 @clone_noncloneable(ptr addrspace(1) nonnull "java-klass"="423456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %flags.addr = getelementptr i8, ptr %klass, i64 172
  %flags = load atomic i32, ptr %flags.addr unordered, align 4
  %clone.flags = and i32 %flags, -1073741824
  %flags.ok = icmp eq i32 %clone.flags, -2147483648
  ret i1 %flags.ok
}

; CHECK-LABEL: define i1 @clone_noncloneable(
; CHECK-NEXT: ret i1 false

define i32 @fold_known_allocation_klass() {
  %allocation = call ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 123456 to ptr), i32 24, i1 false)
  %flags.addr = getelementptr i8, ptr inttoptr (i64 123456 to ptr), i64 172
  %flags = load atomic i32, ptr %flags.addr unordered, align 4
  ret i32 %flags
}

; CHECK-LABEL: define i32 @fold_known_allocation_klass(
; CHECK-NEXT: %allocation = call ptr addrspace(1) @jeandle.new_instance(
; CHECK-NEXT: ret i32 -2147483648

define i32 @keep_native_address() {
  %flags = load i32, ptr inttoptr (i64 123628 to ptr)
  ret i32 %flags
}

; CHECK-LABEL: define i32 @keep_native_address(
; CHECK: load i32, ptr inttoptr (i64 123628 to ptr)

define i32 @keep_volatile(ptr addrspace(1) nonnull "java-klass"="123456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %addr = getelementptr i8, ptr %klass, i64 172
  %flags = load volatile i32, ptr %addr
  ret i32 %flags
}

; CHECK-LABEL: define i32 @keep_volatile(
; CHECK: load volatile i32,

define i32 @keep_acquire(ptr addrspace(1) nonnull "java-klass"="123456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %addr = getelementptr i8, ptr %klass, i64 172
  %flags = load atomic i32, ptr %addr acquire, align 4
  ret i32 %flags
}

; CHECK-LABEL: define i32 @keep_acquire(
; CHECK: load atomic i32, {{.*}} acquire,

define i32 @keep_unavailable(ptr addrspace(1) nonnull "java-klass"="123456" "java-klass-exact" %obj) {
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %addr = getelementptr i8, ptr %klass, i64 44
  %value = load i32, ptr %addr
  ret i32 %value
}

; CHECK-LABEL: define i32 @keep_unavailable(
; CHECK: load i32,

!java-method-compilation = !{}
