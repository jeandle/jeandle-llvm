; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each -mtriple=x86_64-unknown-linux-gnu %s | FileCheck %s --check-prefix=X86 --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.new_array' --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.vectorized_hashcode' --implicit-check-not='mul nsw' --implicit-check-not='mul nuw' --implicit-check-not='add nsw' --implicit-check-not='add nuw'
; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s --check-prefix=SERIAL --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.new_array' --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.vectorized_hashcode' --implicit-check-not='mul nsw' --implicit-check-not='mul nuw' --implicit-check-not='add nsw' --implicit-check-not='add nuw'
; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each -mtriple=aarch64-unknown-linux-gnu %s | FileCheck %s --check-prefix=SERIAL --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.new_array' --implicit-check-not='{{call|invoke}}{{.*}}@jeandle.vectorized_hashcode' --implicit-check-not='mul nsw' --implicit-check-not='mul nuw' --implicit-check-not='add nsw' --implicit-check-not='add nuw'
;
; Adjacent affine segments compose only for x86. A module with only a
; datalayout and a non-x86 target retain the serial arithmetic.
target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
@arrayOopDesc.base_offset_in_bytes.short = constant i32 16
@arrayOopDesc.base_offset_in_bytes.char = constant i32 16
@arrayOopDesc.base_offset_in_bytes.int = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @jeandle.vectorized_hashcode(ptr addrspace(1), i32, i32, i32, i32)
declare i32 @__gxx_personality_v0(...)

; X86-LABEL: @even(
; X86: [[B0:%.*]] = mul i32 %x, 31
; X86: [[B1:%.*]] = add i32 [[B0]], %y
; X86: [[H0:%.*]] = mul i32 %seed, 961
; X86: [[H1:%.*]] = add i32 [[H0]], [[B1]]
; X86: [[B2:%.*]] = mul i32 %z, 31
; X86: [[B3:%.*]] = add i32 [[B2]], %w
; X86: [[H2:%.*]] = mul i32 [[H1]], 961
; X86: [[H3:%.*]] = add i32 [[H2]], [[B3]]
; X86: ret i32 [[H3]]
; SERIAL-LABEL: @even(
; SERIAL-COUNT-4: mul i32 {{%.*}}, 31
; SERIAL-NOT: mul i32
; SERIAL: ret i32
define i32 @even(i32 %x, i32 %y, i32 %z, i32 %w, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %y, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %z, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %w, ptr addrspace(1) %p3 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 4, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @odd(
; X86: mul i32 %x, 31
; X86: mul i32 %seed, 961
; X86: [[P:%.*]] = add i32
; X86: [[T:%.*]] = mul i32 [[P]], 31
; X86: [[R:%.*]] = add i32 [[T]], %z
; X86: ret i32 [[R]]
; SERIAL-LABEL: @odd(
; SERIAL: ret i32
define i32 @odd(i32 %x, i32 %y, i32 %z, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 3, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %y, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %z, ptr addrspace(1) %p2 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 3, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @mixed_runs(
; X86: mul i32 %x, 961
; X86: add i32 {{%.*}}, 216
; X86: mul i32 %seed, 29791
; X86: mul i32 %y, 31
; X86: add i32 {{%.*}}, %z
; X86: mul i32 {{%.*}}, 961
; X86: mul i32 {{%.*}}, 961
; X86: add i32 {{%.*}}, 5
; X86: ret i32
; SERIAL-LABEL: @mixed_runs(
; SERIAL: ret i32
define i32 @mixed_runs(i32 %x, i32 %y, i32 %z, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 7, i32 48, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 7, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 -1, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %y, ptr addrspace(1) %p3 unordered, align 4
  %p4 = getelementptr i8, ptr addrspace(1) %a, i64 32
  store atomic i32 %z, ptr addrspace(1) %p4 unordered, align 4
  %p5 = getelementptr i8, ptr addrspace(1) %a, i64 36
  store atomic i32 0, ptr addrspace(1) %p5 unordered, align 4
  %p6 = getelementptr i8, ptr addrspace(1) %a, i64 40
  store atomic i32 5, ptr addrspace(1) %p6 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 7, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @leading_run(
; X86: add i32 6696, %x
; X86: mul i32 %seed, 29791
; X86: mul i32 {{%.*}}, 31
; X86: add i32 {{%.*}}, %y
; X86: ret i32
; SERIAL-LABEL: @leading_run(
; SERIAL: ret i32
define i32 @leading_run(i32 %x, i32 %y, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 7, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 -1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %x, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 %y, ptr addrspace(1) %p3 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 4, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @zero_seed(
; X86: [[Z0:%.*]] = mul i32 %x, 31
; X86: [[Z1:%.*]] = add i32 [[Z0]], %y
; X86: [[Z2:%.*]] = mul i32 [[Z1]], 31
; X86: [[Z3:%.*]] = add i32 [[Z2]], %z
; X86-NOT: mul i32 0,
; X86: ret i32 [[Z3]]
; SERIAL-LABEL: @zero_seed(
; SERIAL: ret i32
define i32 @zero_seed(i32 %x, i32 %y, i32 %z) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 3, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 %x, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 %y, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 %z, ptr addrspace(1) %p2 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 3, i32 0, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @signed_bytes(
; X86: [[X:%.*]] = sext i8 %x to i32
; X86: [[Y:%.*]] = sext i8 %y to i32
; X86: sext i8 %z to i32
; X86: mul i32 [[X]], 31
; X86: mul i32 %seed, 961
; X86: mul i32 {{%.*}}, 31
; X86: ret i32
; SERIAL-LABEL: @signed_bytes(
; SERIAL: ret i32
define i32 @signed_bytes(i8 %x, i8 %y, i8 %z, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 3, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i8 %x, ptr addrspace(1) %p0 unordered, align 1
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 17
  store atomic i8 %y, ptr addrspace(1) %p1 unordered, align 1
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i8 %z, ptr addrspace(1) %p2 unordered, align 1
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 3, i32 %seed, i32 8)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @signed_shorts(
; X86: [[SX:%.*]] = sext i16 %x to i32
; X86: [[SY:%.*]] = sext i16 %y to i32
; X86: mul i32 [[SX]], 31
; X86: add i32 {{%.*}}, [[SY]]
; X86: mul i32 %seed, 961
; X86: ret i32
; SERIAL-LABEL: @signed_shorts(
; SERIAL: ret i32
define i32 @signed_shorts(i16 %x, i16 %y, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10003 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 %x, ptr addrspace(1) %p0 unordered, align 2
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 %y, ptr addrspace(1) %p1 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 %seed, i32 9)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @unsigned_chars(
; X86: [[CX:%.*]] = zext i16 %x to i32
; X86: [[CY:%.*]] = zext i16 %y to i32
; X86: mul i32 [[CX]], 31
; X86: add i32 {{%.*}}, [[CY]]
; X86: mul i32 %seed, 961
; X86: ret i32
; SERIAL-LABEL: @unsigned_chars(
; SERIAL: ret i32
define i32 @unsigned_chars(i16 %x, i16 %y, i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i16 %x, ptr addrspace(1) %p0 unordered, align 2
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
  store atomic i16 %y, ptr addrspace(1) %p1 unordered, align 2
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 2, i32 %seed, i32 5)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; X86-LABEL: @constant_run(
; X86: [[C:%.*]] = mul i32 %seed, 923521
; X86: [[CR:%.*]] = add i32 [[C]], 207581
; X86: ret i32 [[CR]]
; SERIAL-LABEL: @constant_run(
; SERIAL: mul i32 %seed, 923521
; SERIAL: add i32 {{%.*}}, 207581
; SERIAL: ret i32
define i32 @constant_run(i32 %seed) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10004 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
  %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
  store atomic i32 7, ptr addrspace(1) %p0 unordered, align 4
  %p1 = getelementptr i8, ptr addrspace(1) %a, i64 20
  store atomic i32 -1, ptr addrspace(1) %p1 unordered, align 4
  %p2 = getelementptr i8, ptr addrspace(1) %a, i64 24
  store atomic i32 0, ptr addrspace(1) %p2 unordered, align 4
  %p3 = getelementptr i8, ptr addrspace(1) %a, i64 28
  store atomic i32 5, ptr addrspace(1) %p3 unordered, align 4
  %r = call i32 @jeandle.vectorized_hashcode(ptr addrspace(1) %a, i32 0, i32 4, i32 %seed, i32 10)
  ret i32 %r
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

!java-method-compilation = !{}
