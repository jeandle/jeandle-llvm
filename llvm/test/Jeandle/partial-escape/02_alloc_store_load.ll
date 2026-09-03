; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; PEA: allocate, store one field, load it back, return the loaded
; value.  All accesses are confined to the invoke's normal-dest block so the
; single-block eligibility rule keeps the object virtual.  PEA should erase
; the allocation, the store, and the load — the function reduces to `ret i32
; 42`.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_store_load() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
         to label %normal unwind label %unwind

normal:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %v

unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_store_load()
; CHECK-NOT: jeandle.new_instance
; CHECK-NOT: store
; CHECK-NOT: load
; CHECK: ret i32 42

!java-method-compilation = !{}
