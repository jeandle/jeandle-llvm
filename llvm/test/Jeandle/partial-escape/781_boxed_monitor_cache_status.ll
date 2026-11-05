; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-vm-callback-log=%S/Inputs/781_boxed_monitor_cache_status.cblog %s | FileCheck %s

; A semantic box only blocks lock elimination when valueOf may return a shared
; cache object. The VM callback answers exact integral constants from the live
; cache, while Float/Double are known to allocate for every payload.

declare hotspotcc ptr addrspace(1) @jeandle.box(i32, ptr, i64)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind

@java_lang_boxing_object.value_offset = private constant i32 16
@java_lang_boxing_object.long_value_offset = private constant i32 16

define void @cached_integer_monitor() gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  ret void
}

define void @fresh_integer_monitor() gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 4, ptr inttoptr (i64 400 to ptr), i64 1000)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  ret void
}

define void @fresh_float_monitor(i64 %raw) gc "hotspotgc" {
entry:
  %lock = alloca i64, align 8
  %box = call hotspotcc ptr addrspace(1) @jeandle.box(
      i32 6, ptr inttoptr (i64 600 to ptr), i64 %raw)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %box, ptr %lock)
  ret void
}

!java-method-compilation = !{}

; CHECK-LABEL: define void @cached_integer_monitor
; CHECK: @jeandle.box
; CHECK: @jeandle.monitorenter_with_lightweight_lock
; CHECK: @jeandle.monitorexit_with_lightweight_lock

; CHECK-LABEL: define void @fresh_integer_monitor
; CHECK-NOT: @jeandle.box
; CHECK-NOT: @jeandle.monitorenter_with_lightweight_lock
; CHECK-NOT: @jeandle.monitorexit_with_lightweight_lock
; CHECK: ret void

; CHECK-LABEL: define void @fresh_float_monitor
; CHECK-NOT: @jeandle.box
; CHECK-NOT: @jeandle.monitorenter_with_lightweight_lock
; CHECK-NOT: @jeandle.monitorexit_with_lightweight_lock
; CHECK: ret void
