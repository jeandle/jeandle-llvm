; RUN: opt -S -passes='character-intrinsic-specialization,instcombine,simplifycfg' -verify-each %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64"
@arrayOopDesc.base_offset_in_bytes.byte = constant i32 24
@arrayOopDesc.base_offset_in_bytes.char = constant i32 32

declare hotspotcc i32 @jeandle.encode_array(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, i1, i1)
declare hotspotcc i32 @jeandle.count_positives(ptr addrspace(1), i32, i32)

; CHECK-LABEL: @ascii_prefix(
; CHECK: getelementptr i8, ptr addrspace(1) %src, i64 34
; CHECK: load atomic i16, {{.*}} unordered, align 2
; CHECK: icmp ugt i16 {{.*}}, 127
; CHECK: br i1
; CHECK: store atomic i8
; CHECK: load atomic i16
; CHECK: icmp ugt i16 {{.*}}, 127
; CHECK: br i1
; CHECK: store atomic i8
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
define i32 @ascii_prefix(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 1, ptr addrspace(1) %dst, i32 2, i32 2, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @byte_utf16(
; CHECK: load atomic i8
; CHECK: icmp eq i8 {{.*}}, 0
; CHECK: br i1
; CHECK: load atomic i8
; CHECK: store atomic i8
; CHECK-NOT: @jeandle.encode_array
; CHECK: ret i32
define i32 @byte_utf16(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 1, i1 true, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @scan(
; CHECK: load atomic i8
; CHECK: icmp slt i8 {{.*}}, 0
; CHECK: load atomic i8
; CHECK: icmp slt i8 {{.*}}, 0
; CHECK-NOT: @jeandle.count_positives
; CHECK: ret i32
define i32 @scan(ptr addrspace(1) %src) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 3, i32 2)
  ret i32 %r
}

; CHECK-LABEL: @empty(
; CHECK-NOT: load
; CHECK-NOT: store
; CHECK-NOT: call
; CHECK: ret i32 0
define i32 @empty(ptr addrspace(1) %src, ptr addrspace(1) %dst) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 0, i1 false, i1 true)
  ret i32 %r
}

; CHECK-LABEL: @budget_limit(
; CHECK: call hotspotcc i32 @jeandle.count_positives
; CHECK: ret i32
define i32 @budget_limit(ptr addrspace(1) %src) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 16)
  ret i32 %r
}

; CHECK-LABEL: @over_budget(
; CHECK: call hotspotcc i32 @jeandle.count_positives
define i32 @over_budget(ptr addrspace(1) %src) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 17)
  ret i32 %r
}

; CHECK-LABEL: @dynamic(
; CHECK: call hotspotcc i32 @jeandle.encode_array
define i32 @dynamic(ptr addrspace(1) %src, ptr addrspace(1) %dst, i32 %n) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 %n, i1 false, i1 false)
  ret i32 %r
}

; CHECK-LABEL: @dynamic_mode(
; CHECK: call hotspotcc i32 @jeandle.encode_array
define i32 @dynamic_mode(ptr addrspace(1) %src, ptr addrspace(1) %dst, i1 %ascii) {
  %r = call hotspotcc i32 @jeandle.encode_array(ptr addrspace(1) %src, i32 0, ptr addrspace(1) %dst, i32 0, i32 1, i1 false, i1 %ascii)
  ret i32 %r
}

; CHECK-LABEL: @bundled(
; CHECK: call hotspotcc i32 @jeandle.count_positives{{.*}}[ "deopt"(i32 7) ]
define i32 @bundled(ptr addrspace(1) %src) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 1) [ "deopt"(i32 7) ]
  ret i32 %r
}

declare i32 @personality(...)
; CHECK-LABEL: @invoke_scan(
; CHECK-NOT: invoke
; CHECK: load atomic i8
; CHECK-NOT: landingpad
; CHECK: ret i32
define i32 @invoke_scan(ptr addrspace(1) %src) personality ptr @personality {
entry:
  %r = invoke hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 1) to label %normal unwind label %unwind
normal:
  ret i32 %r
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: @negative(
; CHECK: call hotspotcc i32 @jeandle.count_positives
define i32 @negative(ptr addrspace(1) %src) {
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 -1)
  ret i32 %r
}

; CHECK-LABEL: @wrong_cc(
; CHECK: call i32 @jeandle.count_positives
define i32 @wrong_cc(ptr addrspace(1) %src) {
  %r = call i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 1)
  ret i32 %r
}

; The contextual constant is available only on the taken edge. A second
; candidate in the same function exercises analysis queries before CFG edits.
; CHECK-LABEL: @contextual(
; CHECK-NOT: @jeandle.count_positives
; CHECK: load atomic i8
; CHECK: load atomic i8
; CHECK: ret i32
define i32 @contextual(ptr addrspace(1) %src, i32 %n) {
entry:
  %ok = icmp eq i32 %n, 1
  br i1 %ok, label %work, label %out
work:
  %a = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 0, i32 %n)
  %b = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 1, i32 %n)
  %sum = add i32 %a, %b
  ret i32 %sum
out:
  ret i32 -1
}

; CHECK-LABEL: @tail(
; CHECK: musttail call hotspotcc i32 @jeandle.count_positives
define hotspotcc i32 @tail(ptr addrspace(1) %src, i32 %off, i32 %n) {
  %r = musttail call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %src, i32 %off, i32 1)
  ret i32 %r
}

; Local arrays can expose scalar replacement for the larger bounded budget.
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
; CHECK-LABEL: @local16(
; CHECK: @jeandle.new_array
; CHECK: load atomic i8
; CHECK-NOT: @jeandle.count_positives
; CHECK: ret i32
define i32 @local16() {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr null, i32 16, i32 40, i32 24, i32 100, i1 false, i1 false)
  %r = call hotspotcc i32 @jeandle.count_positives(ptr addrspace(1) %a, i32 0, i32 16)
  ret i32 %r
}
