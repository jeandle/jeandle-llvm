; RUN: opt -disable-output -debug-pass-manager -passes='jeandle-inliner,function(print<block-freq>,print<domtree>)' -jeandle-vm-callback-log=%S/Inputs/block-frequency.cblog %s 2>&1 | FileCheck %s --check-prefix=CACHE
; RUN: opt -S -verify-each -passes=jeandle-inline-driver -jeandle-vm-callback-log=%S/Inputs/block-frequency.cblog %s | FileCheck %s --check-prefix=IR
; RUN: opt -disable-output -debug-pass-manager -passes='jeandle-inline-driver,function(print<block-freq>)' -jeandle-vm-callback-log=%S/Inputs/block-frequency.cblog %s 2>&1 | FileCheck %s --check-prefix=CLEANUP

; Reuse the incrementally updated frequencies across call and invoke inlining.
; Other CFG analyses must be rebuilt, and driver cleanup must invalidate BFI.

@jeandle.personality = global ptr null

define hotspotcc i32 @root(i1 %first, i1 %second) #0 personality ptr @jeandle.personality {
entry:
  %a = call hotspotcc i32 @callee(i1 %first) #2 [ "deopt"(i32 7, i32 7) ]
  %b = invoke hotspotcc i32 @callee(i1 %second) #2 [ "deopt"(i32 11, i32 11) ]
          to label %normal unwind label %unwind

normal:
  %sum = add i32 %a, %b
  ret i32 %sum

unwind:
  %lp = landingpad i64 cleanup
  ret i32 -1
}

define available_externally hotspotcc i32 @callee(i1 %condition) #1 {
entry:
  br i1 %condition, label %hot, label %cold, !prof !1

hot:
  %a = call i32 @opaque(i32 1)
  ret i32 %a

cold:
  %b = call i32 @opaque(i32 2)
  ret i32 %b
}

declare i32 @opaque(i32)

attributes #0 = { "java-method"="1" }
attributes #1 = { "java-method"="2" }
attributes #2 = { "monomorphic-target" }

!java-method-compilation = !{}
!static-call-patch-size = !{!0}
!0 = !{i32 5}
!1 = !{!"branch_weights", i32 3, i32 1}

; CACHE: Running analysis: BlockFrequencyAnalysis on root
; CACHE-NOT: Running analysis: BlockFrequencyAnalysis on root
; CACHE: Running pass: BlockFrequencyPrinterPass on root
; CACHE-NOT: Running analysis: BlockFrequencyAnalysis on root
; CACHE: block-frequency-info: root
; CACHE: - entry: {{.*}} int = 18014398509481984
; CACHE: - hot.i: {{.*}} int = 13510798882111488
; CACHE: - cold.i: {{.*}} int = 4503599627370496
; CACHE: - callee.exit: {{.*}} int = 18014398509481984
; CACHE: - hot.i{{[0-9]+}}: {{.*}} int = 13510798882111488
; CACHE: - cold.i{{[0-9]+}}: {{.*}} int = 4503599627370496
; CACHE: Running pass: DominatorTreePrinterPass on root
; CACHE: Running analysis: DominatorTreeAnalysis on root

; IR-LABEL: define hotspotcc i32 @root(
; IR-NOT: @callee
; IR: call i32 @opaque(i32 1)
; IR: call i32 @opaque(i32 2)
; IR: invoke i32 @opaque(i32 1)
; IR: invoke i32 @opaque(i32 2)
; IR-NOT: define available_externally

; CLEANUP: Running analysis: BlockFrequencyAnalysis on root
; CLEANUP-NOT: Running analysis: BlockFrequencyAnalysis on root
; CLEANUP: Running pass: BlockFrequencyPrinterPass on root
; CLEANUP: Running analysis: BlockFrequencyAnalysis on root
; CLEANUP: block-frequency-info: root
