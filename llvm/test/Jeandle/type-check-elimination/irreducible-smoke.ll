; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/irreducible-smoke.cblog %s 2>&1 | FileCheck %s

; Irreducible CFG smoke test: a and b form a cycle with two entries, so neither
; dominates the other. The engine must terminate (in-progress frames contribute
; nothing) and stay conservative: the query in %a is preserved because the
; entry->a edge carries no proof.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(1) "java-klass"="1" %obj, i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" {
entry:
  br i1 %c0, label %a, label %b

a:
  %ra = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %obj)
  br i1 %c1, label %b, label %m

b:
  br i1 %c2, label %a, label %m

m:
  %r = phi i1 [ %ra, %a ], [ %c2, %b ]
  ret i1 %r
}

; The query is preserved and compilation terminates.
; CHECK: a:
; CHECK-NEXT:   %ra = call i1 @jeandle.check_instanceof

!java-method-compilation = !{}
