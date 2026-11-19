; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s
; RUN: opt -S -verify-each -passes=partial-escape-iterative -jeandle-vm-callback-log=%S/Inputs/770_copy_fold_v2v_full.cblog %s | FileCheck %s

; A fully eliminated Unsafe array can choose zeros. If OrigAlloc is retained,
; its arbitrary payload must not be replaced by the virtual default model.
target datalayout = "e-p:64:64"
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @observe(ptr addrspace(1))
declare void @sink(ptr addrspace(1)) memory(read)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define i32 @uninitialized(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: load atomic
; CHECK: ret i32 0
define i32 @uninitialized(i1 %flag) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 false) to label %read unwind label %unwind
read:
  %p = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @unknown_initialization(
; CHECK: {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %v = load atomic i32
; CHECK: ret i32 %v
define i32 @unknown_initialization(i1 %flag) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 %flag, i1 false) to label %read unwind label %unwind
read:
  %p = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @deferred(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: load atomic
; CHECK: ret i32 0
define i32 @deferred(i1 %flag) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 false, i1 true) to label %read unwind label %unwind
read:
  %p = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @unknown_deferred(
; CHECK: {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_array
; CHECK: %v = load atomic i32
; CHECK: ret i32 %v
define i32 @unknown_deferred(i1 %flag) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 false, i1 %flag) to label %read unwind label %unwind
read:
  %p = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @initialized(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: load atomic
; CHECK: ret i32 0
define i32 @initialized(i1 %flag) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false) to label %read unwind label %unwind
read:
  %p = getelementptr inbounds i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  ret i32 %v
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @initialized_by_copy(
; CHECK: %dest = {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 false)
; CHECK: %src = {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 false, i1 false)
; CHECK: {{(call|invoke)}} void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8
; CHECK: call i32 @observe(ptr addrspace(1) %dest)
define i32 @initialized_by_copy() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
 %dest = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1048576, i1 true, i1 false) to label %new_source unwind label %unwind
new_source:
 %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1048576, i1 false, i1 false) to label %copy unwind label %unwind
copy:
 invoke void @jeandle.copy(ptr addrspace(1) %src, i64 0, ptr addrspace(1) %dest, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #0 to label %escape unwind label %unwind
escape:
 %v = call i32 @observe(ptr addrspace(1) %dest)
 ret i32 %v
unwind:
 %lp = landingpad i64 cleanup
 resume i64 %lp
}
; Read replacements must roll back together with an escaping Unsafe array.
; CHECK-LABEL: define i32 @deferred_escape(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 false, i1 true)
; CHECK: %v = load atomic i32
; CHECK: call i32 @observe(ptr addrspace(1) %a)
; CHECK: ret i32 %v
define i32 @deferred_escape() gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 24, i32 1000, i1 false, i1 true)
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  %ignored = call i32 @observe(ptr addrspace(1) %a)
  ret i32 %v
}

; CHECK-LABEL: define i32 @fully_deferred_escape(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 true)
; CHECK: %v = load atomic i32
; CHECK: call i32 @observe(ptr addrspace(1) %a)
; CHECK: ret i32 %v
define i32 @fully_deferred_escape() gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 true)
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  %ignored = call i32 @observe(ptr addrspace(1) %a)
  ret i32 %v
}

; CHECK-LABEL: define i32 @read_then_escape(
; CHECK: %a = {{(call|invoke)}} hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 false)
; CHECK: %v = load atomic i32
; CHECK: call i32 @observe(ptr addrspace(1) %a)
; CHECK: ret i32 %v
define i32 @read_then_escape() gc "hotspotgc" {
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 false)
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  %ignored = call i32 @observe(ptr addrspace(1) %a)
  ret i32 %v
}

; Synthetic materialization retains its ordinary source allocations. Each
; uninitialized source must therefore be reanalyzed as a real array.
; CHECK-LABEL: define i32 @synthetic_escape(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 false)
; CHECK: %b = call hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 false)
; CHECK: %[[SELECTED:[a-zA-Z0-9_.]+]] = {{(phi|select)}}
; CHECK: %v = load atomic i32
; CHECK: call i32 @observe(ptr addrspace(1) %[[SELECTED]])
; CHECK: ret i32 %v
define i32 @synthetic_escape(i1 %choose) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 false)
  br i1 %choose, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %selected = phi ptr addrspace(1) [ %a, %left ], [ %b, %right ]
  %p = getelementptr i8, ptr addrspace(1) %selected, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  %ignored = call i32 @observe(ptr addrspace(1) %selected)
  ret i32 %v
}

; If an Unsafe source later becomes ineligible, a copy owned by another VO
; must not retain values inferred from the source's virtual zero state.
; CHECK-LABEL: define i32 @ineligible_source(
; CHECK: %a = call hotspotcc ptr addrspace(1) @jeandle.new_array({{.*}}i1 true, i1 false)
; CHECK: %v = load atomic i32
; CHECK: call void @jeandle.copy(ptr addrspace(1) %a
; CHECK: %bv = load atomic i32
; CHECK: %diff = sub i32 %v, %bv
define i32 @ineligible_source(i1 %choose, i64 %offset) gc "hotspotgc" {
entry:
  %a = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 true, i1 false)
  %b = call hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 12345 to ptr), i32 8, i32 48, i32 16, i32 1000, i1 false, i1 false)
  %p = getelementptr i8, ptr addrspace(1) %a, i64 16
  %v = load atomic i32, ptr addrspace(1) %p unordered, align 4
  call void @jeandle.copy(ptr addrspace(1) %a, i64 0, ptr addrspace(1) %b, i64 0, i64 8, ptr null, ptr null, i64 8, i64 8) #0
  %q = getelementptr i8, ptr addrspace(1) %a, i64 %offset
  br i1 %choose, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %selected = phi ptr addrspace(1) [ %q, %left ], [ null, %right ]
  call void @sink(ptr addrspace(1) %selected)
  %bp = getelementptr i8, ptr addrspace(1) %b, i64 16
  %bv = load atomic i32, ptr addrspace(1) %bp unordered, align 4
  %diff = sub i32 %v, %bv
  ret i32 %diff
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" "jeandle.copy.validated" }
!java-method-compilation = !{}
