; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

; Check PEA before generic LLVM simplification: poison/freeze refinement may
; independently fold these expressions, but string content proofs must take
; the conservative path when an explicit undefined input feeds a carrier.
target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare i32 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)

; CHECK-LABEL: @poison_xor(
; CHECK: %a = invoke {{.*}}@jeandle.new_array
; CHECK: %b = invoke {{.*}}@jeandle.new_array
; CHECK: %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
; CHECK: ret i32 %r
define i32 @poison_xor(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %c = xor i1 %flag, poison
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @poison_compare(
; CHECK: %a = invoke {{.*}}@jeandle.new_array
; CHECK: %b = invoke {{.*}}@jeandle.new_array
; CHECK: %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
; CHECK: ret i32 %r
define i32 @poison_compare(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %sum = add i32 %n, poison
 %c = icmp eq i32 %sum, 0
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @poison_shift(
; CHECK: %a = invoke {{.*}}@jeandle.new_array
; CHECK: %b = invoke {{.*}}@jeandle.new_array
; CHECK: %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
; CHECK: ret i32 %r
define i32 @poison_shift(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %shift = shl i32 %n, poison
 %c = trunc i32 %shift to i1
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @poison_extract(
; CHECK: %a = invoke {{.*}}@jeandle.new_array
; CHECK: %b = invoke {{.*}}@jeandle.new_array
; CHECK: %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
; CHECK: ret i32 %r
define i32 @poison_extract(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %c = extractelement <2 x i1> <i1 false, i1 poison>, i32 1
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @undef_arithmetic(
; CHECK: %a = invoke {{.*}}@jeandle.new_array
; CHECK: %b = invoke {{.*}}@jeandle.new_array
; CHECK: %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
; CHECK: ret i32 %r
define i32 @undef_arithmetic(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %bits = and i32 %n, undef
 %c = icmp ne i32 %bits, 0
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @valid_condition(
; CHECK-NOT: jeandle.new_array
; CHECK-NOT: call i32 @jeandle.string_equals
; CHECK: ret i32 1
define i32 @valid_condition(i1 %flag, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %sum = add i32 %n, 1
 %c = icmp ne i32 %sum, 0
 %s = select i1 %c, ptr addrspace(1) %a, ptr addrspace(1) %a
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

!java-method-compilation = !{}
