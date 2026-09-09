; RUN: opt -S -verify-each -passes="partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=4 %s -o %t.once
; RUN: opt -S -verify-each \
; RUN:   -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=4 %s -o %t.twice
; RUN: diff %t.once %t.twice
; RUN: grep -E ' = (call|invoke) hotspotcc ptr addrspace\(1\) @jeandle\.new_instance' %t.twice | count 1
; RUN: grep -F '%%o = call hotspotcc ptr addrspace(1) @jeandle.new_instance' %t.twice | count 1
; RUN: grep -F 'store atomic i32 701, ptr addrspace(1) %%pea.matslot' %t.twice | count 2
; RUN: grep -F 'call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %%o,' %t.twice | count 1
; RUN: grep -F 'call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %%o,' %t.twice | count 1
; RUN: grep -F 'call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %%guard,' %t.twice | count 1
; RUN: grep -F 'call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %%guard,' %t.twice | count 1
; RUN: not grep -E ' = phi ' %t.twice
; RUN: not grep -F poison %t.twice
; RUN: FileCheck %s --check-prefix=STABLE < %t.twice

; The virtual monitor is balanced on both source paths.  The escaping path
; needs one lock replay; each surviving path receives exactly one copy of the
; tracked field value.  A literal second invocation of the iterative wrapper
; must leave the stable allocation, replay stores, PHI-free merge, and monitor
; operations unchanged.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
    ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare void @marker()
declare i32 @__gxx_personality_v0(...)

define void @repeated_pass_stable(i1 %escape, ptr addrspace(1) %guard)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %guard.lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 70100 to ptr), i32 16, i1 false)
       to label %allocated unwind label %unwind
allocated:
  %field = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 701, ptr addrspace(1) %field unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  call void @marker()
  br i1 %escape, label %escaped, label %local
escaped:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
local:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %guard.lock)
  br label %merge
merge:
  %held = phi i1 [ true, %escaped ], [ false, %local ]
  br i1 %held, label %escaped.exit, label %guard.exit
escaped.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br label %done
guard.exit:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %guard, ptr %guard.lock)
  br label %done
done:
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; STABLE-LABEL: define void @repeated_pass_stable(
; STABLE-NOT: @jeandle.new_instance
; STABLE: %o = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; STABLE-NOT: @jeandle.new_instance
; STABLE: call void @marker()
; STABLE-NEXT: br i1 %escape, label %escaped, label %local
; STABLE: escaped:
; STABLE-NEXT: %[[SLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %o, i64 8
; STABLE-NEXT: store atomic i32 701, ptr addrspace(1) %[[SLOT]] unordered, align 4
; STABLE-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %o, ptr{{( nonnull)?}} %lock)
; STABLE-NEXT: call void @sink(ptr addrspace(1) %o)
; STABLE-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %o, ptr{{( nonnull)?}} %lock)
; STABLE-NEXT: br label %done
; STABLE: local:
; STABLE-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %guard, ptr{{( nonnull)?}} %guard.lock)
; STABLE-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %guard, ptr{{( nonnull)?}} %guard.lock)
; STABLE-NEXT: %[[LOCAL_SLOT:pea.matslot[^ ]*]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) %o, i64 8
; STABLE-NEXT: store atomic i32 701, ptr addrspace(1) %[[LOCAL_SLOT]] unordered, align 4
; STABLE-NEXT: br label %done
; STABLE: done:
; STABLE-NOT: = phi
; STABLE-NOT: store atomic i32
; STABLE-NOT: pea.matslot
; STABLE-NOT: poison

!java-method-compilation = !{}
