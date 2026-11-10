; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/layout.cblog -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare i32 @__gxx_personality_v0(...)
declare void @observe_exception()
declare i32 @jeandle.string_compare(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)
declare i32 @jeandle.string_equals(ptr addrspace(1), ptr addrspace(1), i32)
declare i32 @jeandle.string_indexof(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i32)
declare i32 @jeandle.string_indexof_char(ptr addrspace(1), i32, i32, i32, i1)
declare i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_inflate(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)
declare void @jeandle.string_copy_utf16(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)


; A known first source cell followed by an unknown second cell must not commit
; a partial abstract conversion. Both original arrays and the op survive.
; CHECK-LABEL: @rollback(
; CHECK: %a = {{.*}}@jeandle.new_array
; CHECK: %b = {{.*}}@jeandle.new_array
; CHECK: store atomic i8 9
; CHECK: call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b,
; CHECK-NOT: poison
; CHECK: ret i32
 define i32 @rollback(i16 %unknown) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p0 = getelementptr i8, ptr addrspace(1) %a, i64 16
 %p1 = getelementptr i8, ptr addrspace(1) %a, i64 18
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
 store atomic i16 65, ptr addrspace(1) %p0 unordered, align 2
 store atomic i16 %unknown, ptr addrspace(1) %p1 unordered, align 2
 store atomic i8 9, ptr addrspace(1) %bp unordered, align 1
 %r = call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 2, i1 false)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; Unknown ranges through freeze/select/zero GEP carriers materialize both
; arrays, including normal and exceptional uses of an invoke consumer.
; CHECK-LABEL: @aliases(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: invoke i32 @jeandle.string_equals
; CHECK-NOT: poison
; CHECK: landingpad
 define i32 @aliases(i1 %cond, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %az = getelementptr i8, ptr addrspace(1) %a, i64 0
 %af = freeze ptr addrspace(1) %az
 %bs = select i1 %cond, ptr addrspace(1) %b, ptr addrspace(1) %b
 %r = invoke i32 @jeandle.string_equals(ptr addrspace(1) %af, ptr addrspace(1) %bs, i32 %n) to label %done unwind label %u
done:
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 call void @observe_exception()
 resume i64 %lp
}

; Mixed byte/char cells fail layout validation even with equal zero contents.
; CHECK-LABEL: @wrong_layout(
; CHECK: @jeandle.new_array
; CHECK: @jeandle.new_array
; CHECK: call i32 @jeandle.string_equals
; CHECK-NOT: poison
; CHECK: ret i32
 define i32 @wrong_layout() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %a, ptr addrspace(1) %b, i32 2)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}


; A successfully folded write followed by a volatile store materializes the
; original destination and replays the converted prefix before that observer.
; CHECK-LABEL: @destination_materialization(
; CHECK: @jeandle.new_array
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_compress
; CHECK: store atomic i8 65
; CHECK: store volatile i16 257
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1)
 define ptr addrspace(1) @destination_materialization() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %ap = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 65, ptr addrspace(1) %ap unordered, align 2
 %r = call i32 @jeandle.string_compress(ptr addrspace(1) %a, i32 0, ptr addrspace(1) %b, i32 0, i32 2, i1 false)
 %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
 store volatile i16 257, ptr addrspace(1) %bp, align 2
 ret ptr addrspace(1) %b
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; A loop-carried self-PHI can take the conservative path. Both its identity
; observer and the original loop poll must retain valid real operands.
declare void @jeandle.safepoint_poll()
; CHECK-LABEL: @loop_identity(
; CHECK: @jeandle.new_array
; CHECK: call void @jeandle.safepoint_poll
; CHECK: call i32 @jeandle.string_equals
; CHECK-NOT: poison
; CHECK: ret ptr addrspace(1)
 define ptr addrspace(1) @loop_identity(i1 %again) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %loop unwind label %u
loop:
 %p = phi ptr addrspace(1) [ %a, %entry ], [ %p, %loop ]
 call void @jeandle.safepoint_poll()
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %p, ptr addrspace(1) %p, i32 2)
 br i1 %again, label %loop, label %exit
exit:
 ret ptr addrspace(1) %p
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}


; CHECK-LABEL: @derived(
; CHECK: %a = {{.*}}@jeandle.new_array
; CHECK: %b = {{.*}}@jeandle.new_array
; CHECK: call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b,
; CHECK: ret i32
 define i32 @derived(i1 %cond) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %x = getelementptr i8, ptr addrspace(1) %a, i64 1
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @poison_arm(
; CHECK: %a = {{.*}}@jeandle.new_array
; CHECK: %b = {{.*}}@jeandle.new_array
; CHECK: call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b,
; CHECK: ret i32
 define i32 @poison_arm(i1 %cond) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %next unwind label %u
next:
 %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %s = select i1 %cond, ptr addrspace(1) %a, ptr addrspace(1) poison
 %x = freeze ptr addrspace(1) %s
 %r = call i32 @jeandle.string_equals(ptr addrspace(1) %x, ptr addrspace(1) %b, i32 1)
 ret i32 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

!java-method-compilation = !{}
