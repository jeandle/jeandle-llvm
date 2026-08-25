; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Extended intrinsic allowlist. The intrinsics ptr.annotation,
; var.annotation, is.constant, expect, expect.with.probability,
; allow.runtime.check, allow.ubsan.check are pointer-/value-identity-
; preserving and have no effect on a virtual's escape status. The
; allocation must remain eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr addrspace(1) @llvm.ptr.annotation.p1.p0(ptr addrspace(1), ptr, ptr, i32, ptr)
declare i1 @llvm.is.constant.p1(ptr addrspace(1))
declare i64 @llvm.expect.i64(i64, i64)
declare i32 @__gxx_personality_v0(...)

@.str.annotation = private constant [4 x i8] c"foo\00"
@.str.fileinfo  = private constant [4 x i8] c"bar\00"

define i64 @test_ptr_annotation() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  ; Annotation intrinsics: must be no-ops for PEA escape tracking.
  %ann = call ptr addrspace(1) @llvm.ptr.annotation.p1.p0(
                ptr addrspace(1) %o,
                ptr @.str.annotation, ptr @.str.fileinfo, i32 0, ptr null)
  %isc = call i1 @llvm.is.constant.p1(ptr addrspace(1) %o)
  ; expect: pure value passthrough, no virtual involvement.
  %x = call i64 @llvm.expect.i64(i64 7, i64 7)
  ret i64 %x
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i64 @test_ptr_annotation
; CHECK-NOT: jeandle.new_instance
; CHECK: ret i64

!java-method-compilation = !{}
