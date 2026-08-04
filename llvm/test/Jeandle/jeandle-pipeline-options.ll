; RUN: opt -S -passes='jeandle<O3>' --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=METHOD
; RUN: opt -S -passes='jeandle<O3>' -jeandle-inline=off --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=NOINLINE
; RUN: opt -S -passes='jeandle<O3>' -jeandle-inline=accessors-only --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=METHOD
; RUN: opt -S -passes='jeandle<O3>' -jeandle-pea=false --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=NOPEA
; RUN: opt -S -passes='jeandle<O3;method>' --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=METHOD
; RUN: opt -S -passes='jeandle<O3;stub>' --print-pipeline-passes %s 2>&1 | FileCheck %s --check-prefix=NOINLINE
; RUN: not opt -S -passes='jeandle<O3;bogus>' %s 2>&1 | FileCheck %s --check-prefix=BADPARAM
; RUN: not opt -S -passes='jeandle<O2;O3>' %s 2>&1 | FileCheck %s --check-prefix=DUPELEVEL
; RUN: not opt -S -passes='jeandle<O3;stub;method>' %s 2>&1 | FileCheck %s --check-prefix=DUPEMODE
; RUN: not opt -S -passes='jeandle<stub>' %s 2>&1 | FileCheck %s --check-prefix=NOLEVEL
; RUN: opt -S -passes='jeandle<O2>' --print-pipeline-passes %s > %t.passes.txt 2>&1
; RUN: opt -S --jeandle -O2 --print-pipeline-passes %s > %t.flag.txt 2>&1
; RUN: diff %t.passes.txt %t.flag.txt
; RUN: not opt -S --jeandle -passes='jeandle<O3>' %s 2>&1 | FileCheck %s --check-prefix=CONFLICT

define hotspotcc void @pipeline_options() {
entry:
  ret void
}

; METHOD: jeandle-inline-driver
; METHOD: partial-escape-iterative
; NOINLINE-NOT: jeandle-inline-driver
; NOINLINE: partial-escape-iterative
; NOPEA: jeandle-inline-driver
; NOPEA-NOT: partial-escape-iterative
; BADPARAM: invalid jeandle pipeline parameter 'bogus'
; DUPELEVEL: duplicate optimization level parameter 'O3'
; DUPEMODE: duplicate pipeline mode parameter 'method'
; NOLEVEL: missing optimization level for jeandle pipeline
; CONFLICT: Cannot specify --jeandle and --passes
