; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA Case C array-length-mismatch — diamond CFG, both arms allocate arrays
; of the SAME element-Klass but with DIFFERENT compile-time lengths. The
; ArrayLength compatibility check in synthesizeCaseC fails; falls through
; to Case A; both array allocations materialize at their pred terminators.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @test_casec_arr_len_mismatch(i1 %c)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %c, label %left, label %right
left:
  %a1 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
        to label %lcont unwind label %u
lcont:
  br label %merge
right:
  %a2 = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1048576, i1 false, i1 false)
        to label %rcont unwind label %u
rcont:
  br label %merge
merge:
  %p = phi ptr addrspace(1) [ %a1, %lcont ], [ %a2, %rcont ]
  call void @sink(ptr addrspace(1) %p)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Length mismatch -> Case A -> both arrays materialize.
; CHECK-LABEL: define void @test_casec_arr_len_mismatch
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_array{{.*}}i32 4
; CHECK: invoke hotspotcc {{.*}}@jeandle.new_array{{.*}}i32 8
; CHECK: phi ptr addrspace(1)
; CHECK: call void @sink

!java-method-compilation = !{}
