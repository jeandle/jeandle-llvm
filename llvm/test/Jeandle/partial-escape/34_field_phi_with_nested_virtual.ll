; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: diamond CFG where one branch stores a virtual object into the
; outer's reference field, the other stores a non-virtual pointer. The field
; PHI synthesis retains the inner's OrigAlloc and selects between %inner and
; %p in the merge block. The post-merge load
; folds through the field PHI; the outer virtual is eliminated entirely;
; the inner allocation remains at its original left-arm site because it feeds
; the field PHI's left incoming.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_field_phi_nested(i1 %c, ptr addrspace(1) %p)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %outer = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 67890 to ptr), i32 16, i1 false)
           to label %n unwind label %u
n:
  br i1 %c, label %left, label %right
left:
  %inner = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
              ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
           to label %lcont unwind label %u
lcont:
  %sl = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %inner, ptr addrspace(1) %sl unordered, align 8
  br label %merge
right:
  %sr = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  store atomic ptr addrspace(1) %p, ptr addrspace(1) %sr unordered, align 8
  br label %merge
merge:
  %sm = getelementptr inbounds i8, ptr addrspace(1) %outer, i64 8
  %v  = load atomic ptr addrspace(1), ptr addrspace(1) %sm unordered, align 8
  call void @sink(ptr addrspace(1) %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Outer is fully scalar-replaced (no jeandle.new_instance for klass 67890).
; Inner's original jeandle.new_instance for klass 12345 is retained in left.
; The merge block carries a ptr addrspace(1) field PHI selecting between the
; inner OrigAlloc and %p; sink consumes the merged pointer.
; CHECK-LABEL: define void @test_field_phi_nested
; CHECK-NOT: i64 67890
; CHECK: invoke hotspotcc{{.*}}@jeandle.new_instance(ptr inttoptr (i64 12345 to ptr)
; CHECK: = phi ptr addrspace(1)
; CHECK: call void @sink

!java-method-compilation = !{}
