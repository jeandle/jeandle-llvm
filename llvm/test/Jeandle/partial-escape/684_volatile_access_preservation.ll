; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" \
; RUN:   -verify-each %s | FileCheck %s
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -verify-each -jeandle-pea-iterations=8 %s | FileCheck %s

; LLVM volatile accesses are observable operations. PEA must materialize a
; virtual receiver before the first volatile access, preserve each original
; volatile access exactly once, and never replace it with an ordinary replay
; or a folded scalar value.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

; A volatile load is the first unvirtualizable access. The tracked seed store
; is replayed before it, proving that the receiver is materialized at the load;
; the load itself remains volatile rather than folding to 41. The later
; volatile store also remains an observable operation.
define void @test_volatile_load_materializes(i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 68401 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %seed.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %volatile.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 41, ptr addrspace(1) %seed.slot unordered, align 4
  %v = load volatile i32, ptr addrspace(1) %seed.slot, align 4
  store volatile i32 %value, ptr addrspace(1) %volatile.slot, align 4
  call void @use(i32 %v)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_volatile_load_materializes(
; CHECK: @jeandle.new_instance
; CHECK-NOT: store atomic i32 %value
; CHECK-NOT: store atomic i32 41
; CHECK: store atomic i32 41, {{.*}} unordered, align 4
; CHECK-NOT: store atomic i32 41
; CHECK-NOT: store atomic i32 %value
; CHECK-NOT: load volatile
; CHECK: %[[LOADED:[A-Za-z0-9._]+]] = load volatile i32, {{.*}} align 4
; CHECK-NOT: load volatile
; CHECK-NOT: store atomic i32 %value
; CHECK-NOT: store volatile
; CHECK: store volatile i32 %value, {{.*}} align 4
; CHECK-NOT: store volatile
; CHECK-NOT: store atomic i32 %value
; CHECK: call void @use(i32 %[[LOADED]])
; CHECK-NOT: store atomic i32 %value
; CHECK: }

; An atomic volatile store is the first unvirtualizable access on only one CFG
; path. The predecessor's tracked seed must be replayed before that store. Both
; atomic volatile accesses survive exactly once and retain seq_cst ordering.
define void @test_atomic_volatile_store_materializes(i1 %take, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 68402 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %seed.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %volatile.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 17, ptr addrspace(1) %seed.slot unordered, align 4
  br i1 %take, label %volatile.path, label %done
volatile.path:
  store atomic volatile i32 %value, ptr addrspace(1) %volatile.slot seq_cst,
      align 4
  %v = load atomic volatile i32, ptr addrspace(1) %volatile.slot seq_cst,
      align 4
  call void @use(i32 %v)
  call void @sink(ptr addrspace(1) %o)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @test_atomic_volatile_store_materializes(
; CHECK: @jeandle.new_instance
; CHECK: volatile.path:
; CHECK-NOT: store atomic i32 17
; CHECK: store atomic i32 17, {{.*}} unordered, align 4
; CHECK-NOT: store atomic i32 17
; CHECK-NOT: store atomic i32 %value
; CHECK-NOT: store atomic volatile
; CHECK: store atomic volatile i32 %value, {{.*}} seq_cst, align 4
; CHECK-NOT: store atomic volatile
; CHECK-NOT: load atomic volatile
; CHECK: %[[ATOMIC_LOADED:[A-Za-z0-9._]+]] = load atomic volatile i32, {{.*}} seq_cst, align 4
; CHECK-NOT: load atomic volatile
; CHECK-NOT: store atomic i32 %value
; CHECK: call void @use(i32 %[[ATOMIC_LOADED]])
; CHECK-NOT: store atomic i32 %value
; CHECK: call void @sink(ptr addrspace(1)
; CHECK-NOT: store atomic i32 %value
; CHECK: }

!java-method-compilation = !{}
