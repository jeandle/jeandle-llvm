; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; @llvm.ptr.annotation returns its first argument (the annotated pointer) — it
; is pointer-IDENTITY-preserving, exactly like launder/strip.invariant.group.
; When the annotated pointer is then used to access a virtual object's field,
; PEA must forward both identity and the original pointer's byte offset so the
; store/load is tracked on the correct virtual field and the object can be
; scalar-replaced without conflating distinct fields.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare ptr addrspace(1) @llvm.ptr.annotation.p1.p0(ptr addrspace(1), ptr, ptr, i32, ptr)
declare i32 @__gxx_personality_v0(...)

@.str.annotation = private constant [4 x i8] c"foo\00"
@.str.fileinfo  = private constant [4 x i8] c"bar\00"

define i32 @test_ptr_annotation_alias_forward() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %o, i64 0
  store i32 11, ptr addrspace(1) %base
  %field8 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  ; Annotation is transparent to both identity and byte offset. The store
  ; must update offset 8 rather than being confused with the offset-0 field.
  %ann = call ptr addrspace(1) @llvm.ptr.annotation.p1.p0(
                ptr addrspace(1) %field8,
                ptr @.str.annotation, ptr @.str.fileinfo, i32 0, ptr null)
  store i32 22, ptr addrspace(1) %ann
  %v0 = load i32, ptr addrspace(1) %base
  %v8 = load i32, ptr addrspace(1) %ann
  %scaled = mul i32 %v0, 100
  %result = add i32 %scaled, %v8
  ret i32 %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The allocation is eliminated and both field loads forward independently.
; CHECK-LABEL: define i32 @test_ptr_annotation_alias_forward
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: %scaled = mul i32 11, 100
; CHECK: %result = add i32 %scaled, 22
; CHECK: ret i32 %result

!java-method-compilation = !{}
