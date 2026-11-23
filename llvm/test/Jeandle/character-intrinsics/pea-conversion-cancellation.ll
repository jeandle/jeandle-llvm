; RUN: opt -S -passes='instcombine,early-cse,gvn,simplifycfg,character-intrinsic-specialization,java-op-length-folding,string-intrinsic-specialization,character-intrinsic-specialization,instcombine,simplifycfg,loop-simplify,break-crit-edges,loop(loop-rotate,indvars,loop-deletion),pre-pea-allocation-unroll-hints,loop-unroll<no-partial;no-runtime;no-upperbound;full-unroll-max=128;O3>,loop(simple-loop-unswitch<nontrivial>),instcombine,gvn,simplifycfg,adce,simplifycfg,loop-simplify,instcombine,partial-escape-iterative' -jeandle-vm-callback-log=%S/../string-intrinsics/Inputs/symbolic-holder.cblog -verify-each %s | FileCheck %s

; PEA folds the holder's dynamic count before folding the conversion. The
; destination then enters an irreducible loop and loses eligibility. A revived
; reader needs the source initialization at its original position, before the
; conversion, even though the source escapes after that call.
; CHECK-LABEL: define i8 @late_ineligible(
; CHECK: %src = {{.*}}@jeandle.new_array
; CHECK: %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
; CHECK-NEXT: store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
; CHECK: call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src,
; CHECK-NOT: store atomic i16 65
; CHECK: store atomic ptr addrspace(1) %src, ptr @published
; CHECK: ret i8

target datalayout = "e-p:64:64-p1:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
@published = global ptr addrspace(1) null
@holder_published = global ptr addrspace(1) null
@state = global i32 0
declare void @touch_left()
declare void @touch_right()
declare void @sink(ptr addrspace(1))
declare i32 @personality(...)
declare hotspotcc void @jeandle.membar_full() nounwind willreturn "gc-leaf-function"
declare hotspotcc void @jeandle.safepoint_poll()
declare hotspotcc void @jeandle.pre_barrier(ptr addrspace(1))
declare hotspotcc void @jeandle.post_barrier(ptr addrspace(1), ptr addrspace(1))
define i8 @late_ineligible(i1 %first, i1 %repeat) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) [ "deopt"(i32 101, i32 101) ] to label %holder_alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) [ "deopt"(i32 103, i32 103, i64 12, ptr addrspace(1) %src, i64 4294967308, ptr addrspace(1) %holder) ] to label %work unwind label %u
holder_alloc:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 24, i1 false) [ "deopt"(i32 102, i32 102, i64 12, ptr addrspace(1) %src) ] to label %alloc unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  %np = getelementptr i8, ptr addrspace(1) %holder, i64 16
  store atomic i32 1, ptr addrspace(1) %np unordered, align 4
  call hotspotcc void @jeandle.membar_full()
  %n = load atomic i32, ptr addrspace(1) %np unordered, align 4
  store atomic ptr addrspace(1) %holder, ptr @holder_published unordered, align 8
  %positive = icmp sgt i32 %n, 0
  %fits = icmp ule i32 %n, 2
  %ok = and i1 %positive, %fits
  br i1 %ok, label %encode, label %fallback
encode:
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false, i1 false)
  store atomic ptr addrspace(1) %src, ptr @published unordered, align 8
  br i1 %first, label %left, label %right
left:
  store atomic i32 1, ptr @state seq_cst, align 4
  br label %right
right:
  store atomic i32 2, ptr @state seq_cst, align 4
  br i1 %repeat, label %back, label %out
back:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 104, i32 104, i64 12, ptr addrspace(1) %dst) ]
  br label %left
out:
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
fallback:
  ret i8 -1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
declare hotspotcc i32 @jeandle.string_compress(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1)

; String conversions share the same source/destination cancellation transaction.
; CHECK-LABEL: define i8 @late_compress(
; CHECK: %src = {{.*}}@jeandle.new_array
; CHECK: %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
; CHECK-NEXT: store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
; CHECK: call hotspotcc i32 @jeandle.string_compress(ptr addrspace(1) %src,
; CHECK-NOT: store atomic i16 65
; CHECK: store atomic ptr addrspace(1) %src, ptr @published
; CHECK: ret i8

define i8 @late_compress(i1 %first, i1 %repeat) gc "hotspotgc" personality ptr @personality {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10002 to ptr), i32 2, i32 24, i32 16, i32 100, i1 false, i1 false) [ "deopt"(i32 101, i32 101) ] to label %holder_alloc unwind label %u
alloc:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 10001 to ptr), i32 4, i32 24, i32 16, i32 100, i1 false, i1 false) [ "deopt"(i32 103, i32 103, i64 12, ptr addrspace(1) %src, i64 4294967308, ptr addrspace(1) %holder) ] to label %work unwind label %u
holder_alloc:
  %holder = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 100 to ptr), i32 24, i1 false) [ "deopt"(i32 102, i32 102, i64 12, ptr addrspace(1) %src) ] to label %alloc unwind label %u
work:
  %sp = getelementptr i8, ptr addrspace(1) %src, i64 16
  store atomic i16 65, ptr addrspace(1) %sp unordered, align 2
  %np = getelementptr i8, ptr addrspace(1) %holder, i64 16
  store atomic i32 1, ptr addrspace(1) %np unordered, align 4
  call hotspotcc void @jeandle.membar_full()
  %n = load atomic i32, ptr addrspace(1) %np unordered, align 4
  store atomic ptr addrspace(1) %holder, ptr @holder_published unordered, align 8
  %positive = icmp sgt i32 %n, 0
  %fits = icmp ule i32 %n, 2
  %ok = and i1 %positive, %fits
  br i1 %ok, label %encode, label %fallback
encode:
  %r = call hotspotcc i32 @jeandle.string_compress(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false)
  store atomic ptr addrspace(1) %src, ptr @published unordered, align 8
  br i1 %first, label %left, label %right
left:
  store atomic i32 1, ptr @state seq_cst, align 4
  br label %right
right:
  store atomic i32 2, ptr @state seq_cst, align 4
  br i1 %repeat, label %back, label %out
back:
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i32 104, i32 104, i64 12, ptr addrspace(1) %dst) ]
  br label %left
out:
  %dp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %v = load atomic i8, ptr addrspace(1) %dp unordered, align 1
  ret i8 %v
fallback:
  ret i8 -1
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
!java-method-compilation = !{}
