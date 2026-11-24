; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=1 %s \
; RUN:   | FileCheck %s --check-prefix=IDLE-CAP1-IR
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=1 \
; RUN:   -jeandle-dump-pea-ir-function=idle_canonicalization %s 2>&1 \
; RUN:   | grep '^;; PEA-SUMMARY' \
; RUN:   | FileCheck %s --check-prefix=IDLE-CAP1-SUMMARY
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=1 \
; RUN:   -jeandle-dump-pea-ir-function=idle_canonicalization %s 2>&1 \
; RUN:   | FileCheck %s --check-prefix=IDLE-CAP1-DUMP
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 \
; RUN:   -jeandle-dump-pea-ir-function=idle_canonicalization %s 2>&1 \
; RUN:   | grep '^;; PEA-SUMMARY' \
; RUN:   | FileCheck %s --check-prefix=IDLE-CAP2-SUMMARY
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 \
; RUN:   -jeandle-dump-pea-ir-function=already_stable %s 2>&1 \
; RUN:   | grep '^;; PEA-SUMMARY' \
; RUN:   | FileCheck %s --check-prefix=STABLE-SUMMARY
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 %s \
; RUN:   | FileCheck %s --check-prefix=CHURN-CAP2-IR
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=2 \
; RUN:   -jeandle-dump-pea-ir-function=canonicalization_churn %s 2>&1 \
; RUN:   | grep '^;; PEA-SUMMARY' \
; RUN:   | FileCheck %s --check-prefix=CHURN-CAP2-SUMMARY
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=3 \
; RUN:   -jeandle-dump-pea-ir-function=canonicalization_churn %s 2>&1 \
; RUN:   | grep '^;; PEA-SUMMARY' \
; RUN:   | FileCheck %s --check-prefix=CHURN-CAP3-SUMMARY

; Canonicalization belongs to every outer round, including an idle transform
; and the last round allowed by the cap. A changed final round stops at the
; iteration cap; an unchanged transform followed by unchanged canonical IR is
; a real fixpoint.

declare void @side_effect()

define i32 @idle_canonicalization(i32 %value) {
entry:
  %dead = add i32 %value, 1
  ret i32 0
}

; IDLE-CAP1-IR-LABEL: define i32 @idle_canonicalization(
; IDLE-CAP1-IR-NOT: add i32
; IDLE-CAP1-IR: ret i32 0
; IDLE-CAP1-SUMMARY: PEA-SUMMARY function idle_canonicalization rounds=1 stop=iteration-cap
; IDLE-CAP2-SUMMARY: PEA-SUMMARY function idle_canonicalization rounds=2 stop=fixpoint
; IDLE-CAP1-DUMP: ;; PEA-DUMP after iter=0 function idle_canonicalization transform_idle=1
; IDLE-CAP1-DUMP-NEXT: define i32 @idle_canonicalization(
; IDLE-CAP1-DUMP-NOT: add i32
; IDLE-CAP1-DUMP: ret i32 0
; IDLE-CAP1-DUMP: ;; PEA-SUMMARY function idle_canonicalization rounds=1 stop=iteration-cap

define i32 @already_stable(i32 %value) {
entry:
  ret i32 %value
}

; STABLE-SUMMARY: PEA-SUMMARY function already_stable rounds=1 stop=fixpoint

define i32 @canonicalization_churn(i32 %value) {
entry:
  %zero = mul i32 %value, 0
  %take.dead = icmp ne i32 %zero, 0
  br i1 %take.dead, label %dead, label %live

dead:
  call void @side_effect()
  br label %live

live:
  ret i32 0
}

; InstCombine exposes the constant branch and the final CFG cleanup removes
; its dead successor in the first round. The next idle round must confirm a
; real fixpoint, including when the requested cap would allow a third probe.
; CHURN-CAP2-IR-LABEL: define i32 @canonicalization_churn(
; CHURN-CAP2-IR-NOT: call void @side_effect
; CHURN-CAP2-IR: ret i32 0
; CHURN-CAP2-SUMMARY: PEA-SUMMARY function canonicalization_churn rounds=2 stop=fixpoint
; CHURN-CAP3-SUMMARY: PEA-SUMMARY function canonicalization_churn rounds=2 stop=fixpoint

!java-method-compilation = !{}
