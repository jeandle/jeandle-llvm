; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: diamond CFG, both arms store different i32 values into the same
; virtual's field. The analyzer synthesizes a per-field PHI of i32 at the
; merge block; the post-merge load reads through the PHI; the allocation is
; eliminated.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define i32 @test_field_phi_prim(i1 %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 7, ptr addrspace(1) %sl unordered, align 4
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 13, ptr addrspace(1) %sr unordered, align 4
  br label %merge
merge:
  %sm = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v  = load atomic i32, ptr addrspace(1) %sm unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_field_phi_prim
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store atomic
; CHECK-NOT: load atomic
; CHECK: = phi i32
; CHECK: ret i32

!java-method-compilation = !{}
