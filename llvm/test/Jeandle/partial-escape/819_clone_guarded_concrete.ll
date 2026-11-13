; RUN: opt -S -passes=verify %s | FileCheck %s --check-prefix=INPUT
; RUN: opt -S -verify-each -passes="constant-field-folding,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/819_clone_guarded_concrete.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes="constant-field-folding,partial-escape-iterative" -jeandle-pea-iterations=16 -jeandle-vm-callback-log=%S/Inputs/819_clone_guarded_concrete.cblog %s | FileCheck %s
;
; A successful guard gives a concrete clone an exact runtime klass, while the
; receiver's declaration can still name a superclass. Clone folding must use
; the call-site facts and accept compatible non-exact bounds. Conflicting
; exact types and unrelated class bounds keep their original copies.
target datalayout = "e-p:64:64-p1:64:64"
@instanceOopDesc.base_offset_in_bytes = constant i64 16

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr @jeandle.load_klass(ptr addrspace(1))
declare i1 @jeandle.check_instanceof(ptr, ptr addrspace(1) nonnull)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; INPUT-LABEL: define i32 @guarded_clone(
; INPUT: call ptr @jeandle.load_klass
; INPUT: @jeandle.new_instance(ptr %klass,
; INPUT: call void @jeandle.copy
; CHECK-LABEL: define i32 @guarded_clone(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.copy
; CHECK: getelementptr inbounds {{.*}}i8, ptr addrspace(1) %src, i64 16
; CHECK-NEXT: {{%[^ ]+}} = load atomic i32, {{.*}} unordered, align 4
; CHECK-NOT: @jeandle.copy
; CHECK: }
define i32 @guarded_clone(ptr addrspace(1) nonnull "java-klass"="1000" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 30001 to ptr), ptr addrspace(1) %src)
  br i1 %check, label %alloc, label %fail
alloc:
  %klass = call ptr @jeandle.load_klass(ptr addrspace(1) %src)
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 24, i1 false) to label %copy unwind label %u
copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #0
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
fail:
  ret i32 -1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; INPUT-LABEL: define i32 @compatible_supertype(
; INPUT: @jeandle.new_instance
; INPUT: call void @jeandle.copy
; CHECK-LABEL: define i32 @compatible_supertype(
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: @jeandle.copy
; CHECK: getelementptr inbounds {{.*}}i8, ptr addrspace(1) %src, i64 16
; CHECK-NEXT: %[[VALUE:[^ ]+]] = load atomic i32, {{.*}} unordered, align 4
; CHECK-NEXT: ret i32 %[[VALUE]]
define i32 @compatible_supertype(ptr addrspace(1) nonnull "java-klass"="1000" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 30001 to ptr), i32 24, i1 false) to label %copy unwind label %u
copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #0
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; INPUT-LABEL: define i32 @exact_mismatch(
; INPUT: @jeandle.new_instance
; INPUT: call void @jeandle.copy
; CHECK-LABEL: define i32 @exact_mismatch(
; CHECK: @jeandle.new_instance
; CHECK: call void @jeandle.copy
; CHECK: load atomic i32
define i32 @exact_mismatch(ptr addrspace(1) nonnull "java-klass"="1000" "java-klass-exact" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 30001 to ptr), i32 24, i1 false) to label %copy unwind label %u
copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #0
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; INPUT-LABEL: define i32 @incompatible_supertype(
; INPUT: @jeandle.new_instance
; INPUT: call void @jeandle.copy
; CHECK-LABEL: define i32 @incompatible_supertype(
; CHECK: @jeandle.new_instance
; CHECK: call void @jeandle.copy
; CHECK: load atomic i32
define i32 @incompatible_supertype(ptr addrspace(1) nonnull "java-klass"="30002" %src) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 30001 to ptr), i32 24, i1 false) to label %copy unwind label %u
copy:
  call void @jeandle.copy(ptr addrspace(1) %src, i64 16, ptr addrspace(1) %dst, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #0
  %addr = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %value = load atomic i32, ptr addrspace(1) %addr unordered, align 4
  ret i32 %value
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }
!java-method-compilation = !{}
