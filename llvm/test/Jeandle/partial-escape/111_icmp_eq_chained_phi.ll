; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Chained Case-B PHI: a Case-B PHI itself feeds into a second Case-B PHI
; at a deeper merge. processBlockPhis must alias the second PHI to the
; same virtual ObjectID because both of its incomings (the first PHI
; on one path, and another value that aliases to the same virtual on
; the other) carry the alias.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_icmp_eq_chained_phi(i1 %c1, i1 %c2)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  br i1 %c1, label %a, label %b
a:
  br label %m1
b:
  br label %m1
m1:
  ; first Case-B PHI: incomings are both %o (which aliases to the virtual)
  %phi1 = phi ptr addrspace(1) [ %o, %a ], [ %o, %b ]
  br i1 %c2, label %c, label %d
c:
  br label %m2
d:
  br label %m2
m2:
  ; second Case-B PHI: incomings are both %phi1 (which now aliases to
  ; the same virtual). The fix must propagate the alias here too.
  %phi2 = phi ptr addrspace(1) [ %phi1, %c ], [ %phi1, %d ]
  %eq = icmp eq ptr addrspace(1) %phi2, %o
  br i1 %eq, label %same, label %diff
same:
  call void @use(i32 1)
  ret void
diff:
  call void @use(i32 -1)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The chained alias resolves all the way back to the same ObjectID
; on both sides, fold eq to true, the alloc is eliminated.
; CHECK-LABEL: define void @test_icmp_eq_chained_phi
; CHECK-NOT: @jeandle.new_instance
; CHECK-NOT: pea.mat
; CHECK: call void @use(i32 1)
; CHECK-NOT: call void @use(i32 -1)

!java-method-compilation = !{}
