; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck --check-prefix=DEFAULT %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-max-array-length=32 %s | FileCheck --check-prefix=LOW %s
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-max-array-length=128 %s | FileCheck --check-prefix=HIGH %s

; jeandle-pea-max-array-length default is 128.
; This test pins both a 33-element array (below the 128 default but above
; the LOW override of 32) and a 129-element array (always above the cap)
; into the same IR so the cap can be exercised by varying the cl::opt:
;
;   * DEFAULT (no flag passed): cap is 128. The 33-elem array virtualizes
;     and folds to its constant length; the 129-elem array bypasses PEA.
;   * LOW (-jeandle-pea-max-array-length=32): cap is 32. Both arrays
;     bypass PEA — both jeandle.new_array invokes survive.
;   * HIGH (-jeandle-pea-max-array-length=128): same observable effect
;     as DEFAULT (the flag is set explicitly to the default).
;
; Folding manifests as: jeandle.new_array gone + jeandle.arraylength
; replaced with the constant length integer.

declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly)
declare i32 @__gxx_personality_v0(...)

define i32 @test_len33() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 33, i32 148, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_len129() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %arr = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(
            ptr inttoptr (i64 12345 to ptr), i32 129, i32 532, i32 16, i32 1048576, i1 false, i1 false)
         to label %n unwind label %u
n:
  %len = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %arr)
  ret i32 %len
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; DEFAULT (cap=128): 33 virtualized, 129 bypassed.
; DEFAULT-LABEL: define i32 @test_len33
; DEFAULT-NOT: jeandle.new_array
; DEFAULT-NOT: jeandle.arraylength
; DEFAULT: ret i32 33

; DEFAULT-LABEL: define i32 @test_len129
; DEFAULT: invoke{{.*}}@jeandle.new_array{{.*}}i32 129
; DEFAULT: call{{.*}}@jeandle.arraylength

; LOW (cap=32): both bypassed.
; LOW-LABEL: define i32 @test_len33
; LOW: invoke{{.*}}@jeandle.new_array{{.*}}i32 33
; LOW: call{{.*}}@jeandle.arraylength

; LOW-LABEL: define i32 @test_len129
; LOW: invoke{{.*}}@jeandle.new_array{{.*}}i32 129
; LOW: call{{.*}}@jeandle.arraylength

; HIGH (cap=128): same as DEFAULT.
; HIGH-LABEL: define i32 @test_len33
; HIGH-NOT: jeandle.new_array
; HIGH-NOT: jeandle.arraylength
; HIGH: ret i32 33

; HIGH-LABEL: define i32 @test_len129
; HIGH: invoke{{.*}}@jeandle.new_array{{.*}}i32 129
; HIGH: call{{.*}}@jeandle.arraylength

!java-method-compilation = !{}
