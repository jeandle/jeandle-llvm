; RUN: split-file %s %t
; RUN: not --crash opt -S -passes="java-operation-lower<phase=0>" %t/bogus.ll 2>&1 | FileCheck %s --check-prefix=BOGUS
; RUN: not --crash opt -S -passes="java-operation-lower<phase=0>" %t/overflow.ll 2>&1 | FileCheck %s --check-prefix=OVERFLOW
; RUN: opt -S -passes="java-operation-lower<phase=0>" %t/valid.ll 2>&1 | FileCheck %s --check-prefix=VALID

; BOGUS: LLVM ERROR: invalid lower-phase attribute value 'bogus' on function 'bad_bogus'

; OVERFLOW: LLVM ERROR: invalid lower-phase attribute value '99999999999999999999' on function 'bad_overflow'

; VALID-LABEL: define i32 @root()
; VALID-NOT: call i32 @op_phase0
; VALID: call i32 @op_phase1()
; VALID: ret i32

;--- bogus.ll
define i32 @root() #0 {
entry:
  %0 = call i32 @bad_bogus()
  ret i32 %0
}

define i32 @bad_bogus() #1 {
  ret i32 1
}

attributes #0 = { "noinline" }
attributes #1 = { "lower-phase"="bogus" "noinline" }

;--- overflow.ll
define i32 @root() #0 {
entry:
  %0 = call i32 @bad_overflow()
  ret i32 %0
}

define i32 @bad_overflow() #1 {
  ret i32 1
}

attributes #0 = { "noinline" }
attributes #1 = { "lower-phase"="99999999999999999999" "noinline" }

;--- valid.ll
define i32 @root() #0 {
entry:
  %0 = call i32 @op_phase0()
  %1 = call i32 @op_phase1()
  %2 = add i32 %0, %1
  ret i32 %2
}

define i32 @op_phase0() #1 {
  ret i32 42
}

define i32 @op_phase1() #2 {
  ret i32 7
}

attributes #0 = { "noinline" }
attributes #1 = { "lower-phase"="0" "noinline" }
attributes #2 = { "lower-phase"="1" "noinline" }
