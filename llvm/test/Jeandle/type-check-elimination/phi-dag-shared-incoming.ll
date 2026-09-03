; RUN: opt -S -passes="type-check-elimination" -jeandle-vm-callback-log=%S/Inputs/phi-dag-shared-incoming.cblog %s 2>&1 | FileCheck %s

; A PHI feeding two different arms must not be treated as a cycle. %q flows
; into %pn0 both directly (via B1, where a passing check constrains it to
; klass 22) and through %r (via B3, where nothing constrains it). The B3 path
; leaves %q's type open, so %pn0's type is unknown and the query must NOT
; fold. Treating %q as "already visited" while computing the B2 arm would drop
; the unconstrained path, join {22} with {9} to LCA = 5 and fold the query.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define i1 @test(ptr addrspace(0) %p0, ptr addrspace(0) %p1, ptr addrspace(0) %p2, i1 %c0, i1 %c1, i1 %c2) gc "hotspotgc" {
entry:
  br i1 %c0, label %QA, label %QB

QA:
  %q1 = load ptr addrspace(1), ptr addrspace(0) %p0
  br label %QS

QB:
  %q2 = load ptr addrspace(1), ptr addrspace(0) %p1
  br label %QS

QS:
  %q = phi ptr addrspace(1) [ %q1, %QA ], [ %q2, %QB ]
  br i1 %c1, label %B1, label %G

B1:
  %ck = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 22 to ptr addrspace(0)), ptr addrspace(1) nonnull %q)
  br i1 %ck, label %M, label %exit

G:
  br i1 %c2, label %B3, label %SB

B3:
  br label %RS

SB:
  %s = load ptr addrspace(1), ptr addrspace(0) %p2, !java-klass !1
  br label %RS

RS:
  %r = phi ptr addrspace(1) [ %q, %B3 ], [ %s, %SB ]
  br label %M

M:
  %pn0 = phi ptr addrspace(1) [ %q, %B1 ], [ %r, %RS ]
  %res = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 5 to ptr addrspace(0)), ptr addrspace(1) nonnull %pn0)
  ret i1 %res

exit:
  ret i1 false
}

; The query at the merge must stay: the B3/RS path reaches %pn0 with an
; unconstrained %q, so no common klass is provable.
; CHECK: M:
; CHECK-NEXT:   %pn0 = phi ptr addrspace(1)
; CHECK-NEXT:   %res = call i1 @jeandle.check_instanceof
; CHECK-NEXT:   ret i1 %res

!java-method-compilation = !{}
!1 = !{i64 9}
