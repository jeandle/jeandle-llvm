; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-pea.cblog -verify-each %s | FileCheck %s

; RUN: opt -S -passes='require<partial-escape-analysis>,partial-escape-transform,instcombine,simplifycfg' -jeandle-vm-callback-log=%S/Inputs/getchar-pea.cblog -verify-each %s | FileCheck %s --check-prefix=RAW

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 16
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1), i32) nounwind memory(read)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: @default_word(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 0
define i16 @default_word(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @stored_word(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 %value
define i16 @stored_word(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %p unordered, align 2
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @overlapping_bytes(
; CHECK: @jeandle.new_array
; CHECK: store atomic i8 18
; CHECK: store atomic i8 -91
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK-NOT: poison
; CHECK: ret i16
define i16 @overlapping_bytes(i32 %index) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %q = getelementptr i8, ptr addrspace(1) %a, i64 17
 store atomic i8 18, ptr addrspace(1) %p unordered, align 1
 store atomic i8 -91, ptr addrspace(1) %q unordered, align 1
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @dynamic_index(
; CHECK: @jeandle.new_array
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK-NOT: poison
; CHECK: ret i16
define i16 @dynamic_index(i32 %index) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 %index)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @tail_index(
; CHECK: @jeandle.new_array
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK-NOT: poison
; CHECK: ret i16
define i16 @tail_index(i32 %index) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 2)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

!java-method-compilation = !{}

; RAW-LABEL: @raw_default_word(
; RAW-NOT: @jeandle.new_array
; RAW-NOT: load atomic i16
; RAW: ret i16 0
define i16 @raw_default_word(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 %r = load atomic i16, ptr addrspace(1) %p unordered, align 2
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; RAW-LABEL: @raw_stored_word(
; RAW-NOT: @jeandle.new_array
; RAW-NOT: load atomic i16
; RAW: ret i16 %value
define i16 @raw_stored_word(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %p = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %p unordered, align 2
 %r = load atomic i16, ptr addrspace(1) %p unordered, align 2
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @holder_word(
; CHECK-NOT: @jeandle.new_
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 %value
define i16 @holder_word(i16 %value) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %allocate_holder unwind label %u
allocate_holder:
 %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 24, i1 false) to label %work unwind label %u
work:
 %slot = getelementptr i8, ptr addrspace(1) %holder, i64 16
 store atomic ptr addrspace(1) %a, ptr addrspace(1) %slot unordered, align 8
 %loaded = load atomic ptr addrspace(1), ptr addrspace(1) %slot unordered, align 8
 %data = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %data unordered, align 2
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %loaded, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; CHECK-LABEL: @partial_tail(
; CHECK: @jeandle.new_array
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16
define i16 @partial_tail(i32 %index) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 3, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %a, i32 1)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; All defined arms carry the same whole-array identity.
; CHECK-LABEL: @phi_word(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 %value
define i16 @phi_word(i16 %value, i1 %condition) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %data = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %data unordered, align 2
 br i1 %condition, label %left, label %right
left:
 %zero = getelementptr i8, ptr addrspace(1) %a, i64 0
 br label %join
right:
 %frozen = freeze ptr addrspace(1) %a
 br label %join
join:
 %array = phi ptr addrspace(1) [%zero, %left], [%frozen, %right]
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; The self backedge preserves one whole-array identity.
; CHECK-LABEL: @loop_word(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.string_getchar
; CHECK: ret i16 %value
define i16 @loop_word(i16 %value, i1 %again) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %data = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %data unordered, align 2
 br label %loop
loop:
 %array = phi ptr addrspace(1) [%a, %work], [%array, %loop]
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
 br i1 %again, label %loop, label %exit
exit:
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}

; Freeze cannot prove that a poison arm denotes the virtual array.
; CHECK-LABEL: @poison_carrier(
; CHECK: @jeandle.new_array
; CHECK: store atomic i16 %value
; CHECK: call hotspotcc i16 @jeandle.string_getchar
; CHECK: ret i16
define i16 @poison_carrier(i16 %value, i1 %condition) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 32, i32 16, i32 100, i1 false, i1 false) to label %work unwind label %u
work:
 %data = getelementptr i8, ptr addrspace(1) %a, i64 16
 store atomic i16 %value, ptr addrspace(1) %data unordered, align 2
 %choice = select i1 %condition, ptr addrspace(1) %a, ptr addrspace(1) poison
 %array = freeze ptr addrspace(1) %choice
 %r = call hotspotcc i16 @jeandle.string_getchar(ptr addrspace(1) %array, i32 0)
 ret i16 %r
u:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
