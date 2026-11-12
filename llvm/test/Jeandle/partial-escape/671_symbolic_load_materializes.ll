; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/671_symbolic_load_materializes.cblog %s | FileCheck %s

; processLoad with an unresolvable (symbolic-index) address on a virtual
; int[] that has a tracked constant-index store AND a folded load before the
; symbolic load. The symbolic load cannot be tracked, so the array
; materializes AT the load: the tracked store is
; replayed immediately before it, the earlier folded load stays folded, and
; the symbolic load survives as a real load. Regression guard: marking the
; array ineligible instead would drop the fold function-wide and leave the
; tracked store in place.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @use_int(i32)
declare i32 @__gxx_personality_v0(...)

define i32 @test_symbolic_load(i64 %idx) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
             ptr inttoptr (i64 12345 to ptr), i32 4, i32 32, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %base = getelementptr inbounds i8, ptr addrspace(1) %arr, i32 16
  %p0 = getelementptr inbounds i32, ptr addrspace(1) %base, i64 0
  store atomic i32 44, ptr addrspace(1) %p0 unordered, align 4
  %r0 = load atomic i32, ptr addrspace(1) %p0 unordered, align 4
  call void @use_int(i32 %r0)
  %elem = getelementptr inbounds i32, ptr addrspace(1) %base, i64 %idx
  %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_symbolic_load
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array
; The constant-index load stays folded (a bail would drop it function-wide).
; CHECK: call void @use_int(i32 44)
; The tracked store is replayed immediately before the symbolic load.
; CHECK: %pea.matslot = getelementptr inbounds i8, ptr addrspace(1) %arr, i64 16
; CHECK: store atomic i32 44, ptr addrspace(1) %pea.matslot unordered, align 4
; The symbolic load survives as a real load.
; CHECK: %v = load atomic i32, ptr addrspace(1) %elem unordered, align 4
; CHECK: ret i32 %v

!java-method-compilation = !{}
