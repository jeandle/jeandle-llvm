; RUN: opt -S --jeandle -jeandle-vm-callback-log=%S/Inputs/osr-char-arraycopy-e2e.cblog %s 2>&1 | FileCheck %s
;
; End-to-end replay of a real pre-optimization dump of an OSR compilation of
; TestArrayCopyOSR.copyLoop (char[] locals arrive as naked OSR-buffer loads;
; the OSR-entry checkcast chain is phase-0 expanded and dissolved by the
; pipeline). The edge-facts engine must recover the char[] element type so
; ArrayCopySpecialization selects the jshort disjoint stub and the generic
; stub is dead.
;
; CHECK-NOT: StubRoutines_generic_arraycopy
; CHECK: __jeandle_osr.TestArrayCopyOSR_copyLoop
; CHECK: StubRoutines_arrayof_jshort_disjoint_arraycopy
; CHECK-NOT: StubRoutines_generic_arraycopy
;
; ---- 8< ---- recorded JVM dump (edit only comment lines) ---- 8< ----
; ModuleID = 'TestArrayCopyOSR_copyLoop'
source_filename = "/home/taofengliu/jeandle/jeandle-jdk/build/linux-x86_64-server-fastdebug/images/jdk/lib/server/template.ll"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@jeandle.personality = global ptr null
@DEBUG_MODE = private constant i1 true
@WordSize = private constant i64 8
@KlassArray.base_offset_in_bytes = private constant i32 8
@KlassArray.length_offset_in_bytes = private constant i32 0
@arrayOopDesc.length_offset_in_bytes = private constant i32 16
@arrayOopDesc.base_offset_in_bytes.boolean = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.byte = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.char = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.short = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.int = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.long = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.float = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.double = private constant i32 24
@arrayOopDesc.base_offset_in_bytes.object = private constant i32 24
@arrayOopDesc.element_size.boolean = private constant i32 1
@arrayOopDesc.element_size.byte = private constant i32 1
@arrayOopDesc.element_size.char = private constant i32 2
@arrayOopDesc.element_size.short = private constant i32 2
@arrayOopDesc.element_size.int = private constant i32 4
@arrayOopDesc.element_size.long = private constant i32 8
@arrayOopDesc.element_size.float = private constant i32 4
@arrayOopDesc.element_size.double = private constant i32 8
@arrayOopDesc.element_size.object = private constant i32 8
@Klass.access_flags_offset = private constant i32 172
@Klass.java_mirror_offset = private constant i32 120
@Klass.layout_helper_offset = private constant i32 12
@Klass.secondary_super_cache_offset = private constant i32 40
@Klass.secondary_supers_offset = private constant i32 48
@Klass.super_check_offset_offset = private constant i32 24
@ObjArrayKlass.element_klass_offset = private constant i32 216
@InstanceKlass.init_state_offset = private constant i32 297
@InstanceKlass.fully_initialized = private constant i8 4
@oopDesc.klass_offset_in_bytes = private constant i32 8
@oopDesc.mark_offset_in_bytes = private constant i32 0
@instanceOopDesc.base_offset_in_bytes = private constant i32 16
@JavaThread.tlab_end_offset = private constant i64 472
@JavaThread.tlab_top_offset = private constant i64 456
@markWord.prototype_value = private constant i64 1
@VMOptions.UseTLAB = private constant i1 true
@VMOptions.ZeroTLAB = private constant i1 false
@VMOptions.UseCompressedClassPointers = private constant i1 false
@VMOptions.UseCompressedOops = private constant i1 false
@VMOptions.ArrayOperationPartialInlineSize = private constant i32 32
@VMOptions.ArrayCopyLoadStoreMaxElem = private constant i32 8
@java_lang_ref_Reference.referent_offset = private constant i32 16
@java_lang_Class.klass_offset = private constant i32 16
@java_lang_Class.array_klass_offset = private constant i32 24
@BasicLock.displaced_header_offset_in_bytes = private constant i32 0
@JavaThread.held_monitor_count_offset = private constant i32 1432
@JavaThread.lock_stack_end = private constant i32 1896
@JavaThread.lock_stack_top_offset = private constant i32 1824
@ObjectMonitor.EntryList_offset_no_monitor_value = private constant i32 142
@ObjectMonitor.cxq_offset_no_monitor_value = private constant i32 150
@ObjectMonitor.owner_offset_no_monitor_value = private constant i32 62
@ObjectMonitor.recursions_offset_no_monitor_value = private constant i32 134
@ObjectMonitor.succ_offset_no_monitor_value = private constant i32 158
@ObjectMonitor.ANONYMOUS_OWNER = private constant i64 1
@markWord.clear_lock_mask = private constant i64 -4
@markWord.monitor_value = private constant i64 2
@markWord.unlocked_value = private constant i64 1
@markWord.unused_mark_value = private constant i64 3
@JVM_ACC_IS_VALUE_BASED_CLASS = private constant i32 134217728
@JVM_ACC_HAS_FINALIZER = private constant i32 1073741824
@oopSize = private constant i32 8
@check_recursive_mask_value = private constant i64 -4089
@G1ThreadLocalData.satb_mark_queue_active_offset = private constant i32 64
@G1ThreadLocalData.satb_mark_queue_index_offset = private constant i32 40
@G1ThreadLocalData.satb_mark_queue_buffer_offset = private constant i32 56
@G1ThreadLocalData.dirty_card_queue_index_offset = private constant i32 72
@G1ThreadLocalData.dirty_card_queue_buffer_offset = private constant i32 88
@CardTable.card_shift = private constant i64 9
@ci_card_table_address = private constant i64 140257383972864
@HeapRegion.LogOfHRGrainBytes = private constant i64 24
@G1CardTable.g1_young_card_val = private constant i8 2
@G1CardTable.dirty_card_val = private constant i8 0
@G1BarrierSetRuntime.write_ref_field_pre_entry = private constant i64 140564257413040
@G1BarrierSetRuntime.write_ref_field_post_entry = private constant i64 140564257413952
@SharedRuntime.complete_monitor_unlocking_C = private constant i64 140564268230880
@llvm.used = appending addrspace(1) global [7 x ptr] [ptr @jeandle.card_table_barrier, ptr @jeandle.g1_pre_barrier, ptr @jeandle.g1_post_barrier, ptr @jeandle.pre_barrier, ptr @jeandle.post_barrier, ptr @jeandle.encode_heap_oop, ptr @jeandle.decode_heap_oop], section "llvm.metadata"

@SharedRuntime_OSR_migration_end = alias ptr, inttoptr (i64 140564268240384 to ptr)

; Function Attrs: noinline nounwind
define private hotspotcc ptr @jeandle.decode_klass(i32 %0) #0 {
entry:
  %1 = zext i32 %0 to i64
  %2 = inttoptr i64 %1 to ptr
  ret ptr %2
}

; Function Attrs: noinline nounwind
define private hotspotcc i32 @jeandle.encode_klass(ptr %0) #0 {
entry:
  %1 = ptrtoint ptr %0 to i64
  %2 = trunc i64 %1 to i32
  ret i32 %2
}

; Function Attrs: noinline nounwind
define private hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3) %0) #1 {
entry:
  %1 = ptrtoint ptr addrspace(3) %0 to i32
  %2 = zext i32 %1 to i64
  %3 = inttoptr i64 %2 to ptr addrspace(1)
  ret ptr addrspace(1) %3
}

; Function Attrs: noinline nounwind
define private hotspotcc ptr addrspace(3) @jeandle.encode_heap_oop(ptr addrspace(1) %0) #1 {
entry:
  %1 = ptrtoint ptr addrspace(1) %0 to i64
  %2 = trunc i64 %1 to i32
  %3 = inttoptr i32 %2 to ptr addrspace(3)
  ret ptr addrspace(3) %3
}

; Function Attrs: noinline nounwind
define hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) captures(none) %oop) #0 {
  %klass_offset = load i32, ptr @oopDesc.klass_offset_in_bytes, align 4
  %klass_addr = getelementptr inbounds i8, ptr addrspace(1) %oop, i32 %klass_offset
  %use_compressed = load i1, ptr @VMOptions.UseCompressedClassPointers, align 1
  br i1 %use_compressed, label %compressed, label %uncompressed

compressed:                                       ; preds = %0
  %narrow = load atomic i32, ptr addrspace(1) %klass_addr unordered, align 4
  %decoded = call hotspotcc ptr @jeandle.decode_klass(i32 %narrow)
  ret ptr %decoded

uncompressed:                                     ; preds = %0
  %wide = load atomic ptr, ptr addrspace(1) %klass_addr unordered, align 8
  ret ptr %wide
}

; Function Attrs: noinline nounwind
define hotspotcc i1 @jeandle.check_exact_klass(ptr captures(none) %expected_klass, ptr captures(none) %actual_klass) #0 {
  %is_exact = icmp eq ptr %actual_klass, %expected_klass
  ret i1 %is_exact
}

; Function Attrs: noinline nounwind
define hotspotcc ptr @jeandle.load_mirror_klass(ptr addrspace(1) readonly captures(none) %mirror) #0 {
entry:
  %klass_offset = load i32, ptr @java_lang_Class.klass_offset, align 4
  %klass_addr = getelementptr inbounds i8, ptr addrspace(1) %mirror, i32 %klass_offset
  %klass = load atomic ptr, ptr addrspace(1) %klass_addr unordered, align 8
  ret ptr %klass
}

; Function Attrs: noinline nounwind
define hotspotcc i32 @jeandle.layout_helper(ptr readonly captures(none) %klass) #0 {
entry:
  %layout_helper_offset = load i32, ptr @Klass.layout_helper_offset, align 4
  %layout_helper_addr = getelementptr inbounds i8, ptr %klass, i32 %layout_helper_offset
  %layout_helper = load atomic i32, ptr %layout_helper_addr unordered, align 4
  ret i32 %layout_helper
}

; Function Attrs: noinline nounwind
define hotspotcc i1 @jeandle.klass_is_initialized(ptr readonly captures(none) %klass) #0 {
entry:
  %init_state_offset = load i32, ptr @InstanceKlass.init_state_offset, align 4
  %init_state_addr = getelementptr inbounds i8, ptr %klass, i32 %init_state_offset
  %init_state = load volatile i8, ptr %init_state_addr, align 1
  %fully_initialized = load i8, ptr @InstanceKlass.fully_initialized, align 1
  %is_initialized = icmp eq i8 %init_state, %fully_initialized
  ret i1 %is_initialized
}

; Function Attrs: noinline nounwind
define hotspotcc ptr @jeandle.load_array_element_klass(ptr captures(none) %array_klass) #0 {
  %element_klass_offset = load i32, ptr @ObjArrayKlass.element_klass_offset, align 4
  %element_klass_addr = getelementptr inbounds i8, ptr %array_klass, i32 %element_klass_offset
  %element_klass = load atomic ptr, ptr %element_klass_addr unordered, align 8
  ret ptr %element_klass
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.check_klass_subtype_slow_path(ptr captures(none) %sub_klass, ptr captures(none) %super_klass) #2 {
entry:
  %secondary_supers_offset = load i32, ptr @Klass.secondary_supers_offset, align 4
  %secondary_supers_addr = getelementptr inbounds i8, ptr %sub_klass, i32 %secondary_supers_offset
  %secondary_supers = load atomic ptr, ptr %secondary_supers_addr unordered, align 8
  %length_offset = load i32, ptr @KlassArray.length_offset_in_bytes, align 4
  %length_addr = getelementptr inbounds i8, ptr %secondary_supers, i32 %length_offset
  %length = load atomic i32, ptr %length_addr unordered, align 4
  %base_offset = load i32, ptr @KlassArray.base_offset_in_bytes, align 4
  %base_addr = getelementptr inbounds i8, ptr %secondary_supers, i32 %base_offset
  br label %scan_loop

scan_loop:                                        ; preds = %continue_loop, %entry
  %index = phi i32 [ 0, %entry ], [ %next_index, %continue_loop ]
  %current_ptr = phi ptr [ %base_addr, %entry ], [ %next_ptr, %continue_loop ]
  %scan_done = icmp eq i32 %index, %length
  br i1 %scan_done, label %return_false, label %loop_body

loop_body:                                        ; preds = %scan_loop
  %current_klass = load atomic ptr, ptr %current_ptr unordered, align 8
  %is_match = icmp eq ptr %super_klass, %current_klass
  br i1 %is_match, label %return_true, label %continue_loop

continue_loop:                                    ; preds = %loop_body
  %next_index = add i32 %index, 1
  %next_ptr = getelementptr ptr, ptr %base_addr, i32 %next_index
  br label %scan_loop

return_true:                                      ; preds = %loop_body
  %secondary_super_cache_offset = load i32, ptr @Klass.secondary_super_cache_offset, align 4
  %secondary_super_cache_addr = getelementptr inbounds i8, ptr %sub_klass, i32 %secondary_super_cache_offset
  store atomic ptr %super_klass, ptr %secondary_super_cache_addr unordered, align 8
  ret i1 true

return_false:                                     ; preds = %scan_loop
  ret i1 false
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.check_klass_subtype(ptr captures(none) %sub_klass, ptr captures(none) %super_klass) #3 {
entry:
  %is_same_klass = icmp eq ptr %sub_klass, %super_klass
  br i1 %is_same_klass, label %return_true, label %check_primary_supers

check_primary_supers:                             ; preds = %entry
  %super_check_offset_offset = load i32, ptr @Klass.super_check_offset_offset, align 4
  %super_check_offset_addr = getelementptr inbounds i8, ptr %super_klass, i32 %super_check_offset_offset
  %super_check_offset = load atomic i32, ptr %super_check_offset_addr unordered, align 4
  %super_check_addr = getelementptr inbounds i8, ptr %sub_klass, i32 %super_check_offset
  %super_check = load atomic ptr, ptr %super_check_addr unordered, align 8
  %is_super_match = icmp eq ptr %super_klass, %super_check
  br i1 %is_super_match, label %return_true, label %check_secondary_supers

check_secondary_supers:                           ; preds = %check_primary_supers
  %secondary_super_cache_offset = load i32, ptr @Klass.secondary_super_cache_offset, align 4
  %has_secondary = icmp eq i32 %super_check_offset, %secondary_super_cache_offset
  br i1 %has_secondary, label %slow_path, label %return_false

slow_path:                                        ; preds = %check_secondary_supers
  %is_subtype_slow = call hotspotcc i1 @jeandle.check_klass_subtype_slow_path(ptr %sub_klass, ptr %super_klass)
  br i1 %is_subtype_slow, label %return_true, label %return_false

return_true:                                      ; preds = %slow_path, %check_primary_supers, %entry
  ret i1 true

return_false:                                     ; preds = %slow_path, %check_secondary_supers
  ret i1 false
}

; Function Attrs: noinline nounwind
define hotspotcc i1 @jeandle.check_instanceof(ptr captures(none) %super_klass, ptr addrspace(1) nonnull captures(none) %oop) #0 {
entry:
  %sub_klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) nonnull %oop)
  %is_subtype = call hotspotcc i1 @jeandle.check_klass_subtype(ptr %sub_klass, ptr %super_klass)
  ret i1 %is_subtype
}

; Function Attrs: noinline nounwind
define hotspotcc i32 @jeandle.instanceof(ptr captures(none) %super_klass, ptr addrspace(1) captures(none) %oop) #4 {
entry:
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %return_false, label %check_subtype

return_false:                                     ; preds = %entry
  ret i32 0

check_subtype:                                    ; preds = %entry
  %is_subtype = call hotspotcc i1 @jeandle.check_instanceof(ptr %super_klass, ptr addrspace(1) nonnull captures(none) %oop)
  %is_subtype_ext = zext i1 %is_subtype to i32
  ret i32 %is_subtype_ext
}

declare hotspotcc ptr addrspace(1) @new_instance(ptr, ptr)

; Function Attrs: noinline
define private hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr %klass, i32 %size_in_bytes, i1 %initial_slow_test) #5 {
entry:
  br i1 %initial_slow_test, label %alloc_slow_path, label %check_tlab

check_tlab:                                       ; preds = %entry
  %use_tlab = load i1, ptr @VMOptions.UseTLAB, align 1
  br i1 %use_tlab, label %test_tlab, label %alloc_slow_path

test_tlab:                                        ; preds = %check_tlab
  %tlab_top_offset = load i64, ptr @JavaThread.tlab_top_offset, align 4
  %tlab_end_offset = load i64, ptr @JavaThread.tlab_end_offset, align 4
  %tlab_top_ptr = inttoptr i64 %tlab_top_offset to ptr addrspace(2)
  %tlab_end_ptr = inttoptr i64 %tlab_end_offset to ptr addrspace(2)
  %tlab_old_top = load ptr addrspace(1), ptr addrspace(2) %tlab_top_ptr, align 8
  %tlab_end = load ptr addrspace(1), ptr addrspace(2) %tlab_end_ptr, align 8
  %tlab_new_top = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %size_in_bytes
  %if_tlab_full = icmp uge ptr addrspace(1) %tlab_new_top, %tlab_end
  br i1 %if_tlab_full, label %alloc_slow_path, label %alloc_fast_path

alloc_slow_path:                                  ; preds = %test_tlab, %check_tlab, %entry
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %slow_alloc_obj = call hotspotcc ptr addrspace(1) @new_instance(ptr %klass, ptr %current_thread) [ "deopt"() ]
  br label %return_block

alloc_fast_path:                                  ; preds = %test_tlab
  store ptr addrspace(1) %tlab_new_top, ptr addrspace(2) %tlab_top_ptr, align 8
  %mark_word_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %mark_word_offset
  %klass_offset = load i32, ptr @oopDesc.klass_offset_in_bytes, align 4
  %klass_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %klass_offset
  %prototype_value = load i64, ptr @markWord.prototype_value, align 4
  store atomic i64 %prototype_value, ptr addrspace(1) %mark_word_addr unordered, align 8
  %use_compressed_klass = load i1, ptr @VMOptions.UseCompressedClassPointers, align 1
  br i1 %use_compressed_klass, label %store_narrow_klass, label %store_wide_klass

store_narrow_klass:                               ; preds = %alloc_fast_path
  %narrow_klass = call hotspotcc i32 @jeandle.encode_klass(ptr %klass)
  store atomic i32 %narrow_klass, ptr addrspace(1) %klass_addr unordered, align 4
  br label %post_klass_store

store_wide_klass:                                 ; preds = %alloc_fast_path
  store atomic ptr %klass, ptr addrspace(1) %klass_addr unordered, align 8
  br label %post_klass_store

post_klass_store:                                 ; preds = %store_wide_klass, %store_narrow_klass
  %zero_tlab = load i1, ptr @VMOptions.ZeroTLAB, align 1
  %skip_clear = and i1 %use_tlab, %zero_tlab
  br i1 %skip_clear, label %initialization_membar, label %clear_memory

clear_memory:                                     ; preds = %post_klass_store
  %base_offset = load i32, ptr @instanceOopDesc.base_offset_in_bytes, align 4
  %base_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %base_offset
  %payload_size = sub i32 %size_in_bytes, %base_offset
  call void @llvm.memset.p1.i32(ptr addrspace(1) align 8 %base_addr, i8 0, i32 %payload_size, i1 false)
  br label %initialization_membar

initialization_membar:                            ; preds = %clear_memory, %post_klass_store
  fence release
  br label %return_block

return_block:                                     ; preds = %initialization_membar, %alloc_slow_path
  %obj = phi ptr addrspace(1) [ %tlab_old_top, %initialization_membar ], [ %slow_alloc_obj, %alloc_slow_path ]
  ret ptr addrspace(1) %obj
}

; Function Attrs: noinline nounwind
define hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) readonly captures(none) %array_oop) #0 {
entry:
  %length_offset = load i32, ptr @arrayOopDesc.length_offset_in_bytes, align 4
  %length_addr = getelementptr inbounds i8, ptr addrspace(1) %array_oop, i32 %length_offset
  %length = load atomic i32, ptr addrspace(1) %length_addr unordered, align 4
  ret i32 %length
}

; Function Attrs: noinline nounwind
define private hotspotcc ptr @jeandle.current_thread() #4 {
entry:
  %0 = call i64 @llvm.read_register.i64(metadata !0)
  %1 = inttoptr i64 %0 to ptr
  ret ptr %1
}

declare hotspotcc ptr addrspace(1) @new_array(ptr, i32, ptr)

declare hotspotcc void @SharedRuntime_register_finalizer(ptr, ptr addrspace(1))

declare hotspotcc void @jeandle.arraycopy(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr, ptr, i32, i32) #6

declare hotspotcc void @SharedRuntime_complete_monitor_locking_C(ptr addrspace(1), ptr, ptr)

declare hotspotcc void @__llvm_deoptimize(i32)

declare i32 @StubRoutines_generic_arraycopy(ptr addrspace(1), i32, ptr addrspace(1), i32, i32)

declare hotspotcc void @SharedRuntime_slow_arraycopy_C(ptr addrspace(1), i32, ptr addrspace(1), i32, i32, ptr)

declare void @StubRoutines_jbyte_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jbyte_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jbyte_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jbyte_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jshort_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jshort_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jshort_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jshort_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jint_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jint_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jlong_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jlong_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_jlong_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_jlong_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_oop_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_oop_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare void @StubRoutines_arrayof_oop_disjoint_arraycopy(ptr addrspace(1), ptr addrspace(1), i64)

declare i32 @StubRoutines_checkcast_arraycopy(ptr addrspace(1), ptr addrspace(1), i64, i64, ptr)

; Function Attrs: noinline
define private hotspotcc ptr addrspace(1) @jeandle.new_array(ptr %array_klass, i32 %length, i32 %size_in_bytes, i32 %base_offset, i32 %length_limit) #5 {
entry:
  %too_long = icmp ugt i32 %length, %length_limit
  br i1 %too_long, label %array_slow_path, label %check_tlab

check_tlab:                                       ; preds = %entry
  %use_tlab = load i1, ptr @VMOptions.UseTLAB, align 1
  br i1 %use_tlab, label %test_tlab, label %array_slow_path

test_tlab:                                        ; preds = %check_tlab
  %tlab_top_offset = load i64, ptr @JavaThread.tlab_top_offset, align 4
  %tlab_end_offset = load i64, ptr @JavaThread.tlab_end_offset, align 4
  %tlab_top_ptr = inttoptr i64 %tlab_top_offset to ptr addrspace(2)
  %tlab_end_ptr = inttoptr i64 %tlab_end_offset to ptr addrspace(2)
  %tlab_old_top = load ptr addrspace(1), ptr addrspace(2) %tlab_top_ptr, align 8
  %tlab_end = load ptr addrspace(1), ptr addrspace(2) %tlab_end_ptr, align 8
  %tlab_new_top = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %size_in_bytes
  %if_tlab_full = icmp uge ptr addrspace(1) %tlab_new_top, %tlab_end
  br i1 %if_tlab_full, label %array_slow_path, label %array_fast_path

array_slow_path:                                  ; preds = %test_tlab, %check_tlab, %entry
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %slow_array_oop = call hotspotcc ptr addrspace(1) @new_array(ptr %array_klass, i32 %length, ptr %current_thread) [ "deopt"() ]
  br label %array_return

array_fast_path:                                  ; preds = %test_tlab
  store ptr addrspace(1) %tlab_new_top, ptr addrspace(2) %tlab_top_ptr, align 8
  %mark_word_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %mark_word_offset
  %klass_offset = load i32, ptr @oopDesc.klass_offset_in_bytes, align 4
  %klass_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %klass_offset
  %length_offset = load i32, ptr @arrayOopDesc.length_offset_in_bytes, align 4
  %length_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %length_offset
  %prototype_value = load i64, ptr @markWord.prototype_value, align 4
  store atomic i64 %prototype_value, ptr addrspace(1) %mark_word_addr unordered, align 8
  %array_use_compressed_klass = load i1, ptr @VMOptions.UseCompressedClassPointers, align 1
  br i1 %array_use_compressed_klass, label %array_store_narrow_klass, label %array_store_wide_klass

array_store_narrow_klass:                         ; preds = %array_fast_path
  %array_narrow_klass = call hotspotcc i32 @jeandle.encode_klass(ptr %array_klass)
  store atomic i32 %array_narrow_klass, ptr addrspace(1) %klass_addr unordered, align 4
  br label %array_post_klass_store

array_store_wide_klass:                           ; preds = %array_fast_path
  store atomic ptr %array_klass, ptr addrspace(1) %klass_addr unordered, align 8
  br label %array_post_klass_store

array_post_klass_store:                           ; preds = %array_store_wide_klass, %array_store_narrow_klass
  store atomic i32 %length, ptr addrspace(1) %length_addr unordered, align 4
  %zero_tlab = load i1, ptr @VMOptions.ZeroTLAB, align 1
  %skip_clear = and i1 %use_tlab, %zero_tlab
  br i1 %skip_clear, label %array_init_membar, label %array_clear_memory

array_clear_memory:                               ; preds = %array_post_klass_store
  %base_addr = getelementptr i8, ptr addrspace(1) %tlab_old_top, i32 %base_offset
  %payload_size = sub i32 %size_in_bytes, %base_offset
  %payload_words = lshr exact i32 %payload_size, 3
  %has_payload = icmp ne i32 %payload_words, 0
  br i1 %has_payload, label %array_zero_loop, label %array_init_membar

array_zero_loop:                                  ; preds = %array_zero_loop, %array_clear_memory
  %zi = phi i32 [ 0, %array_clear_memory ], [ %zi_next, %array_zero_loop ]
  %zaddr = getelementptr i64, ptr addrspace(1) %base_addr, i32 %zi
  store volatile i64 0, ptr addrspace(1) %zaddr, align 8
  %zi_next = add nuw nsw i32 %zi, 1
  %zero_done = icmp eq i32 %zi_next, %payload_words
  br i1 %zero_done, label %array_init_membar, label %array_zero_loop

array_init_membar:                                ; preds = %array_zero_loop, %array_clear_memory, %array_post_klass_store
  fence release
  br label %array_return

array_return:                                     ; preds = %array_init_membar, %array_slow_path
  %array_oop = phi ptr addrspace(1) [ %tlab_old_top, %array_init_membar ], [ %slow_array_oop, %array_slow_path ]
  ret ptr addrspace(1) %array_oop
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.card_table_barrier(ptr addrspace(1) %addr) #1 {
entry:
  %0 = ptrtoint ptr addrspace(1) %addr to i64
  %1 = lshr i64 %0, 9
  %2 = getelementptr inbounds i8, ptr inttoptr (i64 140257383972864 to ptr), i64 %1
  store atomic i8 0, ptr %2 unordered, align 1
  ret void
}

; Function Attrs: nounwind
define private hotspotcc void @jeandle.g1_satb_enqueue(ptr addrspace(1) %pre_val) #3 {
entry:
  %index_offset = load i32, ptr @G1ThreadLocalData.satb_mark_queue_index_offset, align 4
  %buffer_offset = load i32, ptr @G1ThreadLocalData.satb_mark_queue_buffer_offset, align 4
  %index_adr = inttoptr i32 %index_offset to ptr addrspace(2)
  %buffer_adr = inttoptr i32 %buffer_offset to ptr addrspace(2)
  %index = load i64, ptr addrspace(2) %index_adr, align 4
  %buffer = load ptr, ptr addrspace(2) %buffer_adr, align 8
  %is_zero = icmp eq i64 %index, 0
  br i1 %is_zero, label %buffer_is_full, label %store_in_buffer

buffer_is_full:                                   ; preds = %entry
  %callee_addr = load i64, ptr @G1BarrierSetRuntime.write_ref_field_pre_entry, align 4
  %callee = inttoptr i64 %callee_addr to ptr
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call void %callee(ptr addrspace(1) %pre_val, ptr %current_thread) #12
  br label %done

store_in_buffer:                                  ; preds = %entry
  %wordsize = load i64, ptr @WordSize, align 4
  %next_index = sub i64 %index, %wordsize
  %log_addr = getelementptr inbounds i8, ptr %buffer, i64 %next_index
  store atomic ptr addrspace(1) %pre_val, ptr %log_addr unordered, align 8
  store atomic i64 %next_index, ptr addrspace(2) %index_adr unordered, align 8
  br label %done

done:                                             ; preds = %store_in_buffer, %buffer_is_full
  ret void
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.g1_pre_barrier(ptr addrspace(1) %addr) #1 {
entry:
  %marking_offset = load i32, ptr @G1ThreadLocalData.satb_mark_queue_active_offset, align 4
  %marking_adr = inttoptr i32 %marking_offset to ptr addrspace(2)
  %marking = load i8, ptr addrspace(2) %marking_adr, align 1
  %is_not_marking = icmp eq i8 %marking, 0
  br i1 %is_not_marking, label %done, label %load_pre_value

done:                                             ; preds = %uncompressed, %compressed, %entry
  ret void

load_pre_value:                                   ; preds = %entry
  %use_compressed = load i1, ptr @VMOptions.UseCompressedOops, align 1
  br i1 %use_compressed, label %compressed, label %uncompressed

compressed:                                       ; preds = %load_pre_value
  %narrow_val = load atomic ptr addrspace(3), ptr addrspace(1) %addr unordered, align 4
  %narrow_is_null = icmp eq ptr addrspace(3) %narrow_val, null
  br i1 %narrow_is_null, label %done, label %decode_narrow

decode_narrow:                                    ; preds = %compressed
  %pre_val_c = addrspacecast ptr addrspace(3) %narrow_val to ptr addrspace(1)
  br label %enqueue

uncompressed:                                     ; preds = %load_pre_value
  %pre_val_u = load atomic ptr addrspace(1), ptr addrspace(1) %addr unordered, align 8
  %wide_is_null = icmp eq ptr addrspace(1) %pre_val_u, null
  br i1 %wide_is_null, label %done, label %enqueue

enqueue:                                          ; preds = %uncompressed, %decode_narrow
  %pre_val = phi ptr addrspace(1) [ %pre_val_c, %decode_narrow ], [ %pre_val_u, %uncompressed ]
  call hotspotcc void @jeandle.g1_satb_enqueue(ptr addrspace(1) %pre_val)
  ret void
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.g1_pre_barrier_loaded(ptr addrspace(1) %pre_val) #1 {
entry:
  %marking_offset = load i32, ptr @G1ThreadLocalData.satb_mark_queue_active_offset, align 4
  %marking_adr = inttoptr i32 %marking_offset to ptr addrspace(2)
  %marking = load i8, ptr addrspace(2) %marking_adr, align 1
  %is_not_marking = icmp eq i8 %marking, 0
  br i1 %is_not_marking, label %done, label %check_null

done:                                             ; preds = %check_null, %entry
  ret void

check_null:                                       ; preds = %entry
  %is_null = icmp eq ptr addrspace(1) %pre_val, null
  br i1 %is_null, label %done, label %enqueue

enqueue:                                          ; preds = %check_null
  call hotspotcc void @jeandle.g1_satb_enqueue(ptr addrspace(1) %pre_val)
  ret void
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.g1_post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #1 {
entry:
  %index_offset = load i32, ptr @G1ThreadLocalData.dirty_card_queue_index_offset, align 4
  %buffer_offset = load i32, ptr @G1ThreadLocalData.dirty_card_queue_buffer_offset, align 4
  %index_adr = inttoptr i32 %index_offset to ptr addrspace(2)
  %buffer_adr = inttoptr i32 %buffer_offset to ptr addrspace(2)
  %addr.int = ptrtoint ptr addrspace(1) %addr to i64
  %card_shift = load i64, ptr @CardTable.card_shift, align 4
  %card_offset = lshr i64 %addr.int, %card_shift
  %ci_card_table_address = load i64, ptr @ci_card_table_address, align 4
  %card_base_addr = inttoptr i64 %ci_card_table_address to ptr
  %card_adr = getelementptr inbounds i8, ptr %card_base_addr, i64 %card_offset
  %oop.int = ptrtoint ptr addrspace(1) %oop to i64
  %xor_val = xor i64 %addr.int, %oop.int
  %hr_grain_bytes = load i64, ptr @HeapRegion.LogOfHRGrainBytes, align 4
  %xor_res = lshr i64 %xor_val, %hr_grain_bytes
  %is_zero = icmp eq i64 %xor_res, 0
  br i1 %is_zero, label %post_barrier_done, label %same_region_filtered

post_barrier_done:                                ; preds = %store_in_buffer, %buffer_is_full, %young_card_filtered, %val_nullptr_filtered, %same_region_filtered, %entry
  ret void

same_region_filtered:                             ; preds = %entry
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %post_barrier_done, label %val_nullptr_filtered

val_nullptr_filtered:                             ; preds = %same_region_filtered
  %card_value = load atomic i8, ptr %card_adr unordered, align 1
  %young_card = load i8, ptr @G1CardTable.g1_young_card_val, align 1
  %is_young = icmp eq i8 %card_value, %young_card
  br i1 %is_young, label %post_barrier_done, label %young_card_filtered

young_card_filtered:                              ; preds = %val_nullptr_filtered
  fence seq_cst
  %card_val_reload = load atomic i8, ptr %card_adr unordered, align 1
  %dirty_card = load i8, ptr @G1CardTable.dirty_card_val, align 1
  %is_dirty = icmp eq i8 %card_val_reload, %dirty_card
  br i1 %is_dirty, label %post_barrier_done, label %store_dirty_block

store_dirty_block:                                ; preds = %young_card_filtered
  store atomic i8 0, ptr %card_adr release, align 1
  %index = load i64, ptr addrspace(2) %index_adr, align 4
  %is_full = icmp eq i64 %index, 0
  br i1 %is_full, label %buffer_is_full, label %store_in_buffer

buffer_is_full:                                   ; preds = %store_dirty_block
  %callee_addr = load i64, ptr @G1BarrierSetRuntime.write_ref_field_post_entry, align 4
  %callee = inttoptr i64 %callee_addr to ptr
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call void %callee(ptr %card_adr, ptr %current_thread) #12
  br label %post_barrier_done

store_in_buffer:                                  ; preds = %store_dirty_block
  %wordsize = load i64, ptr @WordSize, align 4
  %next_index = sub i64 %index, %wordsize
  %buffer = load ptr, ptr addrspace(2) %buffer_adr, align 8
  %log_addr = getelementptr inbounds i8, ptr %buffer, i64 %next_index
  store atomic ptr %card_adr, ptr %log_addr unordered, align 8
  store atomic i64 %next_index, ptr addrspace(2) %index_adr unordered, align 8
  br label %post_barrier_done
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.pre_barrier(ptr addrspace(1) %addr) #1 {
entry:
  call hotspotcc void @jeandle.g1_pre_barrier(ptr addrspace(1) %addr)
  ret void
}

; Function Attrs: noinline nounwind
define private hotspotcc void @jeandle.post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) captures(none) %oop) #1 {
entry:
  call hotspotcc void @jeandle.g1_post_barrier(ptr addrspace(1) %addr, ptr addrspace(1) %oop)
  ret void
}

; Function Attrs: noinline nounwind
define hotspotcc ptr addrspace(1) @jeandle.assume_java_type(ptr addrspace(1) %oop) #0 {
entry:
  ret ptr addrspace(1) %oop
}

; Function Attrs: noinline nounwind
define hotspotcc i1 @jeandle.checkcast(ptr captures(none) %super_klass, ptr addrspace(1) captures(none) %oop) #4 {
entry:
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %return_true, label %check_subtype

return_true:                                      ; preds = %entry
  ret i1 true

check_subtype:                                    ; preds = %entry
  %is_subtype = call hotspotcc i1 @jeandle.check_instanceof(ptr %super_klass, ptr addrspace(1) nonnull captures(none) %oop)
  ret i1 %is_subtype
}

; Function Attrs: noinline nounwind
define hotspotcc i1 @jeandle.array_store_check(ptr addrspace(1) captures(none) %oop, ptr addrspace(1) captures(none) %array_oop) #0 {
entry:
  %is_null = icmp eq ptr addrspace(1) %oop, null
  br i1 %is_null, label %return_true, label %check_subtype

return_true:                                      ; preds = %entry
  ret i1 true

check_subtype:                                    ; preds = %entry
  %array_klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %array_oop)
  %element_klass = call hotspotcc ptr @jeandle.load_array_element_klass(ptr %array_klass)
  %is_subtype = call hotspotcc i1 @jeandle.check_instanceof(ptr %element_klass, ptr addrspace(1) nonnull captures(none) %oop)
  ret i1 %is_subtype
}

; Function Attrs: noinline nounwind
define hotspotcc i32 @jeandle.idiv(i32 %dividend, i32 %divisor) #4 {
entry:
  %is_min_int = icmp eq i32 %dividend, -2147483648
  br i1 %is_min_int, label %check_divisor, label %normal_idiv

check_divisor:                                    ; preds = %entry
  %is_minus_one = icmp eq i32 %divisor, -1
  br i1 %is_minus_one, label %return_min_int, label %normal_idiv

return_min_int:                                   ; preds = %check_divisor
  ret i32 -2147483648

normal_idiv:                                      ; preds = %check_divisor, %entry
  %result = sdiv i32 %dividend, %divisor
  ret i32 %result
}

; Function Attrs: noinline nounwind
define hotspotcc i32 @jeandle.irem(i32 %dividend, i32 %divisor) #4 {
entry:
  %is_min_int = icmp eq i32 %dividend, -2147483648
  br i1 %is_min_int, label %check_divisor, label %normal_irem

check_divisor:                                    ; preds = %entry
  %is_minus_one = icmp eq i32 %divisor, -1
  br i1 %is_minus_one, label %return_zero, label %normal_irem

return_zero:                                      ; preds = %check_divisor
  ret i32 0

normal_irem:                                      ; preds = %check_divisor, %entry
  %result = srem i32 %dividend, %divisor
  ret i32 %result
}

; Function Attrs: noinline nounwind
define hotspotcc i64 @jeandle.ldiv(i64 %dividend, i64 %divisor) #4 {
entry:
  %is_min_long = icmp eq i64 %dividend, -9223372036854775808
  br i1 %is_min_long, label %check_divisor, label %normal_ldiv

check_divisor:                                    ; preds = %entry
  %is_minus_one = icmp eq i64 %divisor, -1
  br i1 %is_minus_one, label %return_min_long, label %normal_ldiv

return_min_long:                                  ; preds = %check_divisor
  ret i64 -9223372036854775808

normal_ldiv:                                      ; preds = %check_divisor, %entry
  %result = sdiv i64 %dividend, %divisor
  ret i64 %result
}

; Function Attrs: noinline nounwind
define hotspotcc i64 @jeandle.lrem(i64 %dividend, i64 %divisor) #4 {
entry:
  %is_min_long = icmp eq i64 %dividend, -9223372036854775808
  br i1 %is_min_long, label %check_divisor, label %normal_lrem

check_divisor:                                    ; preds = %entry
  %is_minus_one = icmp eq i64 %divisor, -1
  br i1 %is_minus_one, label %return_zero, label %normal_lrem

return_zero:                                      ; preds = %check_divisor
  ret i64 0

normal_lrem:                                      ; preds = %check_divisor, %entry
  %result = srem i64 %dividend, %divisor
  ret i64 %result
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.check_if_value_based(ptr addrspace(1) captures(none) %obj) #3 {
entry:
  %obj_klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %access_flags_offset = load i32, ptr @Klass.access_flags_offset, align 4
  %access_flags_addr = getelementptr inbounds i8, ptr %obj_klass, i32 %access_flags_offset
  %access_flags = load i32, ptr %access_flags_addr, align 4
  %is_value_based_mask = load i32, ptr @JVM_ACC_IS_VALUE_BASED_CLASS, align 4
  %masked_value = and i32 %access_flags, %is_value_based_mask
  %is_value_based = icmp ne i32 %masked_value, 0
  ret i1 %is_value_based
}

; Function Attrs: noinline
define hotspotcc void @jeandle.register_finalizer_if_needed(ptr addrspace(1) %obj) #7 {
entry:
  %obj_klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %access_flags_offset = load i32, ptr @Klass.access_flags_offset, align 4
  %access_flags_addr = getelementptr inbounds i8, ptr %obj_klass, i32 %access_flags_offset
  %access_flags = load i32, ptr %access_flags_addr, align 4
  %has_finalizer_mask = load i32, ptr @JVM_ACC_HAS_FINALIZER, align 4
  %masked_value = and i32 %access_flags, %has_finalizer_mask
  %has_finalizer = icmp ne i32 %masked_value, 0
  br i1 %has_finalizer, label %register_finalizer, label %return

register_finalizer:                               ; preds = %entry
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @SharedRuntime_register_finalizer(ptr %current_thread, ptr addrspace(1) %obj)
  br label %return

return:                                           ; preds = %register_finalizer, %entry
  ret void
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.check_inflated(i64 %mark_word) #2 {
entry:
  %markWord_monitor_value = load i64, ptr @markWord.monitor_value, align 4
  %masked_value = and i64 %mark_word, %markWord_monitor_value
  %is_inflated = icmp ne i64 %masked_value, 0
  ret i1 %is_inflated
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.try_acquire_monitor_lock(i64 %mark_word, ptr captures(none) %lock) #2 {
entry:
  %monitor_ptr = inttoptr i64 %mark_word to ptr
  %owner_offset_no_monitor_value = load i32, ptr @ObjectMonitor.owner_offset_no_monitor_value, align 4
  %owner_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %owner_offset_no_monitor_value
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %current_thread_as_int = ptrtoint ptr %current_thread to i64
  %monitor_cas = cmpxchg ptr %owner_addr, i64 0, i64 %current_thread_as_int acq_rel monotonic, align 8
  %displaced_header_offset = load i32, ptr @BasicLock.displaced_header_offset_in_bytes, align 4
  %destory_lock_record_addr = getelementptr inbounds i8, ptr %lock, i32 %displaced_header_offset
  %unused_mark_value = load i64, ptr @markWord.unused_mark_value, align 4
  store i64 %unused_mark_value, ptr %destory_lock_record_addr, align 8
  %monitor_acquied = extractvalue { i64, i1 } %monitor_cas, 1
  br i1 %monitor_acquied, label %return_true, label %check_recursive_monitor

check_recursive_monitor:                          ; preds = %entry
  %monitor_owner = extractvalue { i64, i1 } %monitor_cas, 0
  %is_recursive_monitor_lock = icmp eq i64 %monitor_owner, %current_thread_as_int
  br i1 %is_recursive_monitor_lock, label %increase_recursions, label %return_false

increase_recursions:                              ; preds = %check_recursive_monitor
  %recursions_offset_no_monitor_value = load i32, ptr @ObjectMonitor.recursions_offset_no_monitor_value, align 4
  %recursions_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %recursions_offset_no_monitor_value
  %recursions = load i64, ptr %recursions_addr, align 8
  %new_recursions = add i64 %recursions, 1
  store i64 %new_recursions, ptr %recursions_addr, align 8
  br label %return_true

return_true:                                      ; preds = %increase_recursions, %entry
  ret i1 true

return_false:                                     ; preds = %check_recursive_monitor
  ret i1 false
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.increment_lock_count() #2 {
entry:
  %held_monitor_count_offset = load i32, ptr @JavaThread.held_monitor_count_offset, align 4
  %held_monitor_count_offset_zext = zext i32 %held_monitor_count_offset to i64
  %held_monitor_count_addr = inttoptr i64 %held_monitor_count_offset_zext to ptr addrspace(2)
  %held_monitor_count = load i64, ptr addrspace(2) %held_monitor_count_addr, align 8
  %new_held_monitor_count = add i64 %held_monitor_count, 1
  store i64 %new_held_monitor_count, ptr addrspace(2) %held_monitor_count_addr, align 8
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.decrement_lock_count() #2 {
entry:
  %held_monitor_count_offset = load i32, ptr @JavaThread.held_monitor_count_offset, align 4
  %held_monitor_count_offset_zext = zext i32 %held_monitor_count_offset to i64
  %held_monitor_count_addr = inttoptr i64 %held_monitor_count_offset_zext to ptr addrspace(2)
  %held_monitor_count = load i64, ptr addrspace(2) %held_monitor_count_addr, align 8
  %new_held_monitor_count = sub i64 %held_monitor_count, 1
  store i64 %new_held_monitor_count, ptr addrspace(2) %held_monitor_count_addr, align 8
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.clear_oop_in_lock_stack_top(i32 %lock_stack_top) #2 {
entry:
  %is_debug = load i1, ptr @DEBUG_MODE, align 1
  br i1 %is_debug, label %debug_path, label %release_path

debug_path:                                       ; preds = %entry
  %lock_stack_top_zext = zext i32 %lock_stack_top to i64
  %clear_oop_addr = inttoptr i64 %lock_stack_top_zext to ptr addrspace(2)
  store atomic i64 0, ptr addrspace(2) %clear_oop_addr unordered, align 8
  ret void

release_path:                                     ; preds = %entry
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorenter_with_monitor_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %is_inflated = call hotspotcc i1 @jeandle.check_inflated(i64 %mark_word)
  br i1 %is_inflated, label %monitor_lock_fast_path, label %slow_path

monitor_lock_fast_path:                           ; preds = %entry
  %acquired = call hotspotcc i1 @jeandle.try_acquire_monitor_lock(i64 %mark_word, ptr %lock)
  br i1 %acquired, label %increment_lock_count_and_return, label %slow_path

increment_lock_count_and_return:                  ; preds = %monitor_lock_fast_path
  call hotspotcc void @jeandle.increment_lock_count()
  ret void

slow_path:                                        ; preds = %monitor_lock_fast_path, %entry
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @SharedRuntime_complete_monitor_locking_C(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread)
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorenter_with_thin_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %is_inflated = call hotspotcc i1 @jeandle.check_inflated(i64 %mark_word)
  br i1 %is_inflated, label %monitor_lock_fast_path, label %thin_lock_path

thin_lock_path:                                   ; preds = %entry
  %markWord_unlocked_value = load i64, ptr @markWord.unlocked_value, align 4
  %unlocked_mark_word = or i64 %mark_word, %markWord_unlocked_value
  store i64 %unlocked_mark_word, ptr %lock, align 8
  %lock_as_int = ptrtoint ptr %lock to i64
  %thin_lock_cas = cmpxchg ptr addrspace(1) %mark_word_addr, i64 %unlocked_mark_word, i64 %lock_as_int acq_rel monotonic, align 8
  %thin_lock_acquired = extractvalue { i64, i1 } %thin_lock_cas, 1
  br i1 %thin_lock_acquired, label %increment_lock_count_and_return, label %check_recursive_thin_lock

check_recursive_thin_lock:                        ; preds = %thin_lock_path
  %stack_top = call hotspotcc i64 @jeandle.get_stack_pointer()
  %thin_lock_owner = extractvalue { i64, i1 } %thin_lock_cas, 0
  %offset_from_sp = sub i64 %thin_lock_owner, %stack_top
  %check_recursive_mask_value = load i64, ptr @check_recursive_mask_value, align 4
  %recursive_masked_value = and i64 %offset_from_sp, %check_recursive_mask_value
  store i64 %recursive_masked_value, ptr %lock, align 8
  %is_recursive_thin_lock = icmp eq i64 %recursive_masked_value, 0
  br i1 %is_recursive_thin_lock, label %increment_lock_count_and_return, label %slow_path

monitor_lock_fast_path:                           ; preds = %entry
  %acquired = call hotspotcc i1 @jeandle.try_acquire_monitor_lock(i64 %mark_word, ptr %lock)
  br i1 %acquired, label %increment_lock_count_and_return, label %slow_path

increment_lock_count_and_return:                  ; preds = %monitor_lock_fast_path, %check_recursive_thin_lock, %thin_lock_path
  call hotspotcc void @jeandle.increment_lock_count()
  ret void

slow_path:                                        ; preds = %monitor_lock_fast_path, %check_recursive_thin_lock
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @SharedRuntime_complete_monitor_locking_C(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread)
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %is_inflated = call hotspotcc i1 @jeandle.check_inflated(i64 %mark_word)
  br i1 %is_inflated, label %monitor_lock_fast_path, label %lightweight_lock_path

lightweight_lock_path:                            ; preds = %entry
  %lock_stack_top_offset = load i32, ptr @JavaThread.lock_stack_top_offset, align 4
  %lock_stack_top_offset_zext = zext i32 %lock_stack_top_offset to i64
  %lock_stack_top_addr = inttoptr i64 %lock_stack_top_offset_zext to ptr addrspace(2)
  %lock_stack_top = load i32, ptr addrspace(2) %lock_stack_top_addr, align 4
  %lock_stack_end = load i32, ptr @JavaThread.lock_stack_end, align 4
  %is_lock_stack_full = icmp sge i32 %lock_stack_top, %lock_stack_end
  br i1 %is_lock_stack_full, label %slow_path, label %lightweight_lock

lightweight_lock:                                 ; preds = %lightweight_lock_path
  %markWord_clear_lock_mask = load i64, ptr @markWord.clear_lock_mask, align 4
  %mark_word_clear_lock = and i64 %mark_word, %markWord_clear_lock_mask
  %markWord_unlocked_value = load i64, ptr @markWord.unlocked_value, align 4
  %unlocked_mark_word = or i64 %mark_word_clear_lock, %markWord_unlocked_value
  %lightweight_lock_cas = cmpxchg ptr addrspace(1) %mark_word_addr, i64 %unlocked_mark_word, i64 %mark_word_clear_lock acq_rel monotonic, align 8
  %lightweight_lock_acquired = extractvalue { i64, i1 } %lightweight_lock_cas, 1
  br i1 %lightweight_lock_acquired, label %push_oop_to_lock_stack, label %slow_path

push_oop_to_lock_stack:                           ; preds = %lightweight_lock
  %lock_stack_top_zext = zext i32 %lock_stack_top to i64
  %store_oop_addr = inttoptr i64 %lock_stack_top_zext to ptr addrspace(2)
  store atomic ptr addrspace(1) %obj, ptr addrspace(2) %store_oop_addr unordered, align 8
  %oopSize = load i32, ptr @oopSize, align 4
  %lock_stack_top_increased = add i32 %lock_stack_top, %oopSize
  store i32 %lock_stack_top_increased, ptr addrspace(2) %lock_stack_top_addr, align 4
  br label %increment_lock_count_and_return

monitor_lock_fast_path:                           ; preds = %entry
  %acquired = call hotspotcc i1 @jeandle.try_acquire_monitor_lock(i64 %mark_word, ptr %lock)
  br i1 %acquired, label %increment_lock_count_and_return, label %slow_path

increment_lock_count_and_return:                  ; preds = %monitor_lock_fast_path, %push_oop_to_lock_stack
  call hotspotcc void @jeandle.increment_lock_count()
  ret void

slow_path:                                        ; preds = %monitor_lock_fast_path, %lightweight_lock, %lightweight_lock_path
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @SharedRuntime_complete_monitor_locking_C(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread)
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorexit_with_monitor_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %released = call hotspotcc i1 @jeandle.try_release_monitor_lock(i64 %mark_word)
  br i1 %released, label %decrement_lock_count_and_return, label %slow_path

decrement_lock_count_and_return:                  ; preds = %entry
  call hotspotcc void @jeandle.decrement_lock_count()
  ret void

slow_path:                                        ; preds = %entry
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %callee_addr = load i64, ptr @SharedRuntime.complete_monitor_unlocking_C, align 4
  %callee = inttoptr i64 %callee_addr to ptr
  call void %callee(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread) #12
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorexit_with_thin_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %displaced_header_offset = load i32, ptr @BasicLock.displaced_header_offset_in_bytes, align 4
  %displaced_header_addr = getelementptr inbounds i8, ptr %lock, i32 %displaced_header_offset
  %displaced_header = load i64, ptr %displaced_header_addr, align 8
  %is_recursive_stack_unlock = icmp eq i64 %displaced_header, 0
  br i1 %is_recursive_stack_unlock, label %decrement_lock_count_and_return, label %check_if_lock_is_inflated

check_if_lock_is_inflated:                        ; preds = %entry
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %is_inflated = call hotspotcc i1 @jeandle.check_inflated(i64 %mark_word)
  br i1 %is_inflated, label %monitor_unlock_fast_path, label %thin_unlock_path

thin_unlock_path:                                 ; preds = %check_if_lock_is_inflated
  %lock_as_int = ptrtoint ptr %lock to i64
  %thin_lock_cas = cmpxchg ptr addrspace(1) %mark_word_addr, i64 %lock_as_int, i64 %displaced_header acq_rel monotonic, align 8
  %thin_lock_released = extractvalue { i64, i1 } %thin_lock_cas, 1
  br i1 %thin_lock_released, label %decrement_lock_count_and_return, label %slow_path

monitor_unlock_fast_path:                         ; preds = %check_if_lock_is_inflated
  %released = call hotspotcc i1 @jeandle.try_release_monitor_lock(i64 %mark_word)
  br i1 %released, label %decrement_lock_count_and_return, label %slow_path

decrement_lock_count_and_return:                  ; preds = %monitor_unlock_fast_path, %thin_unlock_path, %entry
  call hotspotcc void @jeandle.decrement_lock_count()
  ret void

slow_path:                                        ; preds = %monitor_unlock_fast_path, %thin_unlock_path
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %callee_addr = load i64, ptr @SharedRuntime.complete_monitor_unlocking_C, align 4
  %callee = inttoptr i64 %callee_addr to ptr
  call void %callee(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread) #12
  ret void
}

; Function Attrs: nounwind
define hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) captures(none) %obj, ptr captures(none) %lock) #3 {
entry:
  %mark_offset = load i32, ptr @oopDesc.mark_offset_in_bytes, align 4
  %mark_word_addr = getelementptr inbounds i8, ptr addrspace(1) %obj, i32 %mark_offset
  %mark_word = load atomic i64, ptr addrspace(1) %mark_word_addr unordered, align 8
  %is_inflated = call hotspotcc i1 @jeandle.check_inflated(i64 %mark_word)
  br i1 %is_inflated, label %check_anonymous_owner, label %lightweight_unlock_path

lightweight_unlock_path:                          ; preds = %entry
  %markWord_unlocked_value = load i64, ptr @markWord.unlocked_value, align 4
  %unlocked_mark_word = or i64 %mark_word, %markWord_unlocked_value
  %lightweight_lock_cas = cmpxchg ptr addrspace(1) %mark_word_addr, i64 %mark_word, i64 %unlocked_mark_word acq_rel monotonic, align 8
  %lightweight_lock_released = extractvalue { i64, i1 } %lightweight_lock_cas, 1
  br i1 %lightweight_lock_released, label %pop_oop_from_lock_stack, label %slow_path

pop_oop_from_lock_stack:                          ; preds = %lightweight_unlock_path
  %lock_stack_top_offset = load i32, ptr @JavaThread.lock_stack_top_offset, align 4
  %lock_stack_top_offset_zext = zext i32 %lock_stack_top_offset to i64
  %lock_stack_top_addr = inttoptr i64 %lock_stack_top_offset_zext to ptr addrspace(2)
  %lock_stack_top = load i32, ptr addrspace(2) %lock_stack_top_addr, align 4
  %oopSize = load i32, ptr @oopSize, align 4
  %new_lock_stack_top = sub i32 %lock_stack_top, %oopSize
  store i32 %new_lock_stack_top, ptr addrspace(2) %lock_stack_top_addr, align 4
  call hotspotcc void @jeandle.clear_oop_in_lock_stack_top(i32 %new_lock_stack_top)
  br label %decrement_lock_count_and_return

check_anonymous_owner:                            ; preds = %entry
  %monitor_ptr = inttoptr i64 %mark_word to ptr
  %owner_offset_no_monitor_value = load i32, ptr @ObjectMonitor.owner_offset_no_monitor_value, align 4
  %owner_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %owner_offset_no_monitor_value
  %owner = load atomic volatile i64, ptr %owner_addr unordered, align 8
  %anonymous_owner_mask = load i64, ptr @ObjectMonitor.ANONYMOUS_OWNER, align 4
  %masked_owner = and i64 %owner, %anonymous_owner_mask
  %is_anonymous_owner = icmp ne i64 %masked_owner, 0
  br i1 %is_anonymous_owner, label %slow_path, label %monitor_unlock_fast_path

monitor_unlock_fast_path:                         ; preds = %check_anonymous_owner
  %released = call hotspotcc i1 @jeandle.try_release_monitor_lock(i64 %mark_word)
  br i1 %released, label %decrement_lock_count_and_return, label %slow_path

decrement_lock_count_and_return:                  ; preds = %monitor_unlock_fast_path, %pop_oop_from_lock_stack
  call hotspotcc void @jeandle.decrement_lock_count()
  ret void

slow_path:                                        ; preds = %monitor_unlock_fast_path, %check_anonymous_owner, %lightweight_unlock_path
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %callee_addr = load i64, ptr @SharedRuntime.complete_monitor_unlocking_C, align 4
  %callee = inttoptr i64 %callee_addr to ptr
  call void %callee(ptr addrspace(1) %obj, ptr %lock, ptr %current_thread) #12
  ret void
}

; Function Attrs: nounwind
define hotspotcc i64 @jeandle.get_stack_pointer() #2 {
  %stack_pointer = call i64 @llvm.read_register.i64(metadata !1)
  ret i64 %stack_pointer
}

; Function Attrs: nounwind
define hotspotcc i1 @jeandle.try_release_monitor_lock(i64 %mark_word) #2 {
entry:
  %monitor_ptr = inttoptr i64 %mark_word to ptr
  %recursions_offset_no_monitor_value = load i32, ptr @ObjectMonitor.recursions_offset_no_monitor_value, align 4
  %recursions_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %recursions_offset_no_monitor_value
  %recursions = load i64, ptr %recursions_addr, align 8
  %is_recursive_monitor_unlock = icmp ne i64 %recursions, 0
  br i1 %is_recursive_monitor_unlock, label %decrease_recursions, label %check_for_waiters

decrease_recursions:                              ; preds = %entry
  %new_recursions = sub i64 %recursions, 1
  store i64 %new_recursions, ptr %recursions_addr, align 8
  br label %return_true

check_for_waiters:                                ; preds = %entry
  %cxq_offset_no_monitor_value = load i32, ptr @ObjectMonitor.cxq_offset_no_monitor_value, align 4
  %cxq_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %cxq_offset_no_monitor_value
  %cxq = load atomic i64, ptr %cxq_addr unordered, align 8
  %EntryList_offset_no_monitor_value = load i32, ptr @ObjectMonitor.EntryList_offset_no_monitor_value, align 4
  %EntryList_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %EntryList_offset_no_monitor_value
  %EntryList = load atomic i64, ptr %EntryList_addr unordered, align 8
  %is_cxq_null = icmp eq i64 %cxq, 0
  %is_EntryList_null = icmp eq i64 %EntryList, 0
  %has_no_waiters = and i1 %is_cxq_null, %is_EntryList_null
  %owner_offset_no_monitor_value = load i32, ptr @ObjectMonitor.owner_offset_no_monitor_value, align 4
  %owner_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %owner_offset_no_monitor_value
  br i1 %has_no_waiters, label %clear_monitor_owner, label %check_candidate_thread

check_candidate_thread:                           ; preds = %check_for_waiters
  %succ_offset_no_monitor_value = load i32, ptr @ObjectMonitor.succ_offset_no_monitor_value, align 4
  %succ_addr = getelementptr inbounds i8, ptr %monitor_ptr, i32 %succ_offset_no_monitor_value
  %succ = load atomic volatile i64, ptr %succ_addr unordered, align 8
  %has_no_candidate_threads = icmp eq i64 %succ, 0
  br i1 %has_no_candidate_threads, label %return_false, label %try_release_monitor

clear_monitor_owner:                              ; preds = %check_for_waiters
  store atomic volatile i64 0, ptr %owner_addr release, align 8
  br label %return_true

try_release_monitor:                              ; preds = %check_candidate_thread
  store atomic volatile i64 0, ptr %owner_addr unordered, align 8
  fence seq_cst
  %new_succ = load atomic volatile i64, ptr %succ_addr unordered, align 8
  %is_candidate_thread_null = icmp eq i64 %new_succ, 0
  br i1 %is_candidate_thread_null, label %reacquire_monitor, label %return_true

reacquire_monitor:                                ; preds = %try_release_monitor
  %current_thread = call hotspotcc ptr @jeandle.current_thread()
  %current_thread_as_int = ptrtoint ptr %current_thread to i64
  %monitor_cas = cmpxchg ptr %owner_addr, i64 0, i64 %current_thread_as_int acq_rel monotonic, align 8
  %monitor_reacquied = extractvalue { i64, i1 } %monitor_cas, 1
  br i1 %monitor_reacquied, label %return_false, label %return_true

return_true:                                      ; preds = %reacquire_monitor, %try_release_monitor, %clear_monitor_owner, %decrease_recursions
  ret i1 true

return_false:                                     ; preds = %reacquire_monitor, %check_candidate_thread
  ret i1 false
}

; Function Attrs: nocallback nofree nounwind willreturn memory(argmem: write)
declare void @llvm.memset.p1.i32(ptr addrspace(1) writeonly captures(none), i8, i32, i1 immarg) #8

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(read)
declare i64 @llvm.read_register.i64(metadata) #9

; Function Attrs: noinline
define private hotspotcc void @jeandle.safepoint_poll() #7 {
entry:
  %0 = load volatile i64, ptr addrspace(2) inttoptr (i64 1160 to ptr addrspace(2)), align 4
  %1 = and i64 %0, 1
  %2 = icmp ne i64 %1, 0
  br i1 %2, label %do_safepoint, label %return

return:                                           ; preds = %do_safepoint, %entry
  ret void

do_safepoint:                                     ; preds = %entry
  %3 = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @safepoint_handler(ptr %3) [ "deopt"() ]
  br label %return
}

declare hotspotcc void @safepoint_handler(ptr)

; Function Attrs: noinline nounwind
define private hotspotcc ptr addrspace(1) @jeandle.get_class(ptr addrspace(1) %0) #0 {
entry:
  %1 = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %0)
  %2 = load i32, ptr @Klass.java_mirror_offset, align 4
  %3 = getelementptr inbounds i8, ptr %1, i32 %2
  %4 = load ptr, ptr %3, align 8
  %5 = load ptr addrspace(1), ptr %4, align 8
  ret ptr addrspace(1) %5
}

; Function Attrs: noinline nounwind
define private hotspotcc ptr addrspace(1) @jeandle.current_thread_obj() #0 {
entry:
  %0 = call hotspotcc ptr @jeandle.current_thread()
  %1 = getelementptr inbounds i8, ptr %0, i32 952
  %2 = load ptr, ptr %1, align 8
  %3 = load ptr addrspace(1), ptr %2, align 8
  ret ptr addrspace(1) %3
}

; Function Attrs: noinline nounwind
define private hotspotcc i32 @jeandle.reference_refers_to(ptr addrspace(1) %0, ptr addrspace(1) %1) #0 {
entry:
  %2 = load i32, ptr @java_lang_ref_Reference.referent_offset, align 4
  %3 = getelementptr inbounds i8, ptr addrspace(1) %0, i32 %2
  %4 = load atomic ptr addrspace(1), ptr addrspace(1) %3 unordered, align 8
  fence syncscope("singlethread") seq_cst
  %5 = icmp eq ptr addrspace(1) %4, %1
  %6 = zext i1 %5 to i32
  ret i32 %6
}

; Function Attrs: noinline nounwind
define private hotspotcc ptr addrspace(1) @jeandle.reference_get(ptr addrspace(1) %0) #0 {
entry:
  %1 = load i32, ptr @java_lang_ref_Reference.referent_offset, align 4
  %2 = getelementptr inbounds i8, ptr addrspace(1) %0, i32 %1
  %3 = load atomic ptr addrspace(1), ptr addrspace(1) %2 unordered, align 8
  call hotspotcc void @jeandle.g1_pre_barrier_loaded(ptr addrspace(1) %3)
  fence syncscope("singlethread") seq_cst
  ret ptr addrspace(1) %3
}

; Function Attrs: nocf_check
define hotspotcc void @"__jeandle_osr.TestArrayCopyOSR_copyLoop([C[CI)V.140563881107680.root"(ptr %0) #10 gc "hotspotgc" personality ptr @jeandle.personality {
entry:
  %OrigPcSlot = alloca i64, align 8
  br label %osr_migration

bci_2:                                            ; preds = %bci_13_normal_dest, %osr_entry_check_locals_done
  %1 = phi ptr addrspace(1) [ %8, %osr_entry_check_locals_done ], [ %1, %bci_13_normal_dest ]
  %2 = phi ptr addrspace(1) [ %10, %osr_entry_check_locals_done ], [ %2, %bci_13_normal_dest ]
  %3 = phi i32 [ %12, %osr_entry_check_locals_done ], [ %3, %bci_13_normal_dest ]
  %4 = phi i32 [ %14, %osr_entry_check_locals_done ], [ %30, %bci_13_normal_dest ]
  %5 = icmp sge i32 %4, %3
  br i1 %5, label %bci_22, label %bci_7, !prof !4

bci_7:                                            ; preds = %bci_2
  %6 = icmp eq ptr addrspace(1) %1, null
  br i1 %6, label %bci_12_null_check_fail, label %bci_12_null_check_pass, !make.implicit !5

bci_22:                                           ; preds = %bci_2
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 0, i32 22, i32 22, i64 99, i32 0, i64 4294967395, i32 0, i64 8589934691, i32 0, i64 12884901987, i32 0, i64 327695, ptr %OrigPcSlot) ]
  ret void

osr_migration:                                    ; preds = %entry
  %7 = getelementptr inbounds i8, ptr %0, i64 24
  %8 = load atomic ptr addrspace(1), ptr %7 unordered, align 8
  %9 = getelementptr inbounds i8, ptr %0, i64 16
  %10 = load atomic ptr addrspace(1), ptr %9 unordered, align 8
  %11 = getelementptr inbounds i8, ptr %0, i64 8
  %12 = load atomic i32, ptr %11 unordered, align 4
  %13 = getelementptr inbounds i8, ptr %0, i64 0
  %14 = load atomic i32, ptr %13 unordered, align 4
  call void inttoptr (i64 140564268240384 to ptr)(ptr %0)
  br label %osr_entry_check_local_0

osr_entry_check_local_0:                          ; preds = %osr_migration
  %15 = call hotspotcc i1 @jeandle.checkcast(ptr inttoptr (i64 140531020484232 to ptr), ptr addrspace(1) %8)
  br i1 %15, label %osr_entry_check_local_1, label %osr_entry_trap_block

osr_entry_trap_block:                             ; preds = %osr_entry_check_local_1, %osr_entry_check_local_0
  call hotspotcc void (...) @llvm.experimental.deoptimize.isVoid(i32 -115) [ "deopt"(i64 1, i32 2, i32 2, i64 12, ptr addrspace(1) %8, i64 4294967308, ptr addrspace(1) %10, i64 8589934602, i32 %12, i64 12884901898, i32 %14, i64 327695, ptr %OrigPcSlot) ]
  ret void

osr_entry_check_local_1:                          ; preds = %osr_entry_check_local_0
  %16 = call hotspotcc i1 @jeandle.checkcast(ptr inttoptr (i64 140531020484232 to ptr), ptr addrspace(1) %10)
  br i1 %16, label %osr_entry_check_locals_done, label %osr_entry_trap_block

osr_entry_check_locals_done:                      ; preds = %osr_entry_check_local_1
  br label %bci_2

bci_12_null_check_pass:                           ; preds = %bci_7
  %17 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %1)
  %18 = icmp eq ptr addrspace(1) %1, null
  br i1 %18, label %bci_13_null_check_fail, label %bci_13_null_check_pass, !make.implicit !5

bci_12_null_check_fail:                           ; preds = %bci_7
  call hotspotcc void (...) @llvm.experimental.deoptimize.isVoid(i32 -10) [ "deopt"(i64 1, i32 12, i32 12, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %4, i64 65548, ptr addrspace(1) %1, i64 4295032842, i32 0, i64 8590000140, ptr addrspace(1) %2, i64 12884967434, i32 0, i64 17179934732, ptr addrspace(1) %1, i64 327695, ptr %OrigPcSlot) ]
  ret void

bci_13_null_check_pass:                           ; preds = %bci_12_null_check_pass
  %19 = icmp eq ptr addrspace(1) %2, null
  br i1 %19, label %bci_13_null_check_fail2, label %bci_13_null_check_pass1, !make.implicit !5

bci_13_null_check_fail:                           ; preds = %bci_12_null_check_pass
  call hotspotcc void (...) @llvm.experimental.deoptimize.isVoid(i32 -10) [ "deopt"(i64 1, i32 13, i32 13, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %4, i64 65548, ptr addrspace(1) %1, i64 4295032842, i32 0, i64 8590000140, ptr addrspace(1) %2, i64 12884967434, i32 0, i64 17179934730, i32 %17, i64 327695, ptr %OrigPcSlot) ]
  ret void

bci_13_null_check_pass1:                          ; preds = %bci_13_null_check_pass
  %arraycopy_klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %1)
  %20 = call hotspotcc i32 @jeandle.layout_helper(ptr %arraycopy_klass)
  %arraycopy_is_array = icmp slt i32 %20, 0
  %arraycopy_guard_not = xor i1 %arraycopy_is_array, true
  br i1 %arraycopy_guard_not, label %arraycopy_guard_slow, label %arraycopy_guard_fast, !prof !6

bci_13_null_check_fail2:                          ; preds = %bci_13_null_check_pass
  call hotspotcc void (...) @llvm.experimental.deoptimize.isVoid(i32 -10) [ "deopt"(i64 1, i32 13, i32 13, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %4, i64 65548, ptr addrspace(1) %1, i64 4295032842, i32 0, i64 8590000140, ptr addrspace(1) %2, i64 12884967434, i32 0, i64 17179934730, i32 %17, i64 327695, ptr %OrigPcSlot) ]
  ret void

arraycopy_slow:                                   ; preds = %arraycopy_guard_slow16, %arraycopy_guard_slow13, %arraycopy_guard_slow11, %arraycopy_guard_slow8, %arraycopy_guard_slow6, %arraycopy_guard_slow
  call hotspotcc void (...) @llvm.experimental.deoptimize.isVoid(i32 -52) [ "deopt"(i64 1, i32 13, i32 13, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %4, i64 65548, ptr addrspace(1) %1, i64 4295032842, i32 0, i64 8590000140, ptr addrspace(1) %2, i64 12884967434, i32 0, i64 17179934730, i32 %17, i64 327695, ptr %OrigPcSlot) ]
  ret void

arraycopy_guard_slow:                             ; preds = %bci_13_null_check_pass1
  br label %arraycopy_slow

arraycopy_guard_fast:                             ; preds = %bci_13_null_check_pass1
  %arraycopy_klass3 = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %2)
  %21 = call hotspotcc i32 @jeandle.layout_helper(ptr %arraycopy_klass3)
  %arraycopy_is_array4 = icmp slt i32 %21, 0
  %arraycopy_guard_not5 = xor i1 %arraycopy_is_array4, true
  br i1 %arraycopy_guard_not5, label %arraycopy_guard_slow6, label %arraycopy_guard_fast7, !prof !6

arraycopy_guard_slow6:                            ; preds = %arraycopy_guard_fast
  br label %arraycopy_slow

arraycopy_guard_fast7:                            ; preds = %arraycopy_guard_fast
  %22 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %1)
  %arraycopy_over = icmp ult i32 %22, %17
  br i1 %arraycopy_over, label %arraycopy_guard_slow8, label %arraycopy_guard_fast9, !prof !7

arraycopy_guard_slow8:                            ; preds = %arraycopy_guard_fast7
  br label %arraycopy_slow

arraycopy_guard_fast9:                            ; preds = %arraycopy_guard_fast7
  %23 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %2)
  %arraycopy_over10 = icmp ult i32 %23, %17
  br i1 %arraycopy_over10, label %arraycopy_guard_slow11, label %arraycopy_guard_fast12, !prof !7

arraycopy_guard_slow11:                           ; preds = %arraycopy_guard_fast9
  br label %arraycopy_slow

arraycopy_guard_fast12:                           ; preds = %arraycopy_guard_fast9
  %arraycopy_index_is_negative = icmp slt i32 %17, 0
  br i1 %arraycopy_index_is_negative, label %arraycopy_guard_slow13, label %arraycopy_guard_fast14, !prof !7

arraycopy_guard_slow13:                           ; preds = %arraycopy_guard_fast12
  br label %arraycopy_slow

arraycopy_guard_fast14:                           ; preds = %arraycopy_guard_fast12
  %arraycopy_index_non_negative = xor i1 %arraycopy_index_is_negative, true
  call void @llvm.assume(i1 %arraycopy_index_non_negative)
  %arraycopy_klass15 = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %2)
  %24 = call hotspotcc i32 @jeandle.instanceof(ptr %arraycopy_klass15, ptr addrspace(1) %1)
  %arraycopy_not_instance = icmp eq i32 %24, 0
  br i1 %arraycopy_not_instance, label %arraycopy_guard_slow16, label %arraycopy_guard_fast17, !prof !7

arraycopy_guard_slow16:                           ; preds = %arraycopy_guard_fast14
  br label %arraycopy_slow

arraycopy_guard_fast17:                           ; preds = %arraycopy_guard_fast14
  %arraycopy_klass18 = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %1)
  %arraycopy_klass19 = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %2)
  %25 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %1)
  %26 = call hotspotcc i32 @jeandle.arraylength(ptr addrspace(1) %2)
  invoke hotspotcc void @jeandle.arraycopy(ptr addrspace(1) %1, i32 0, ptr addrspace(1) %2, i32 0, i32 %17, ptr %arraycopy_klass18, ptr %arraycopy_klass19, i32 %25, i32 %26) #13 [ "deopt"(i64 0, i32 13, i32 13, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %4, i64 327695, ptr %OrigPcSlot) ]
          to label %bci_13_normal_dest unwind label %bci_13_unwind_dest

bci_13_unwind_dest:                               ; preds = %arraycopy_guard_fast17
  %27 = landingpad i64
          cleanup
  %28 = load volatile ptr addrspace(1), ptr addrspace(2) inttoptr (i64 1352 to ptr addrspace(2)), align 8
  store volatile ptr addrspace(1) null, ptr addrspace(2) inttoptr (i64 1352 to ptr addrspace(2)), align 8
  %29 = call hotspotcc ptr @jeandle.current_thread()
  call hotspotcc void @install_exceptional_return(ptr addrspace(1) %28, ptr %29)
  ret void

bci_13_normal_dest:                               ; preds = %arraycopy_guard_fast17
  %30 = add i32 %4, 1
  call hotspotcc void @jeandle.safepoint_poll() [ "deopt"(i64 0, i32 19, i32 19, i64 12, ptr addrspace(1) %1, i64 4294967308, ptr addrspace(1) %2, i64 8589934602, i32 %3, i64 12884901898, i32 %30, i64 327695, ptr %OrigPcSlot) ]
  br label %bci_2
}

declare hotspotcc void @llvm.experimental.deoptimize.isVoid(...)

; Function Attrs: nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write)
declare void @llvm.assume(i1 noundef) #11

declare hotspotcc void @install_exceptional_return(ptr addrspace(1), ptr)

attributes #0 = { noinline nounwind "gc-leaf-function" "lower-phase"="1" }
attributes #1 = { noinline nounwind "gc-leaf-function" "lower-phase"="9" }
attributes #2 = { nounwind "gc-leaf-function" "lower-phase"="0" }
attributes #3 = { nounwind "gc-leaf-function" "lower-phase"="1" }
attributes #4 = { noinline nounwind "gc-leaf-function" "lower-phase"="0" }
attributes #5 = { noinline "jeandle.not-guaranteed-safepoint" "lower-phase"="1" }
attributes #6 = { "lower-phase"="1" }
attributes #7 = { noinline "lower-phase"="1" }
attributes #8 = { nocallback nofree nounwind willreturn memory(argmem: write) }
attributes #9 = { nocallback nofree nosync nounwind willreturn memory(read) }
attributes #10 = { nocf_check "disable-tail-calls"="true" "java-method"="140563881107680" }
attributes #11 = { nocallback nofree nosync nounwind willreturn memory(inaccessiblemem: write) }
attributes #12 = { nounwind "gc-leaf-function" }
attributes #13 = { "jeandle.arraycopy.kind"="arraycopy" "jeandle.arraycopy.negative-length-guard" "jeandle.arraycopy.validated" }

!current-thread = !{!0}
!stack-pointer = !{!1}
!static-call-patch-size = !{!2}
!dynamic-call-patch-size = !{!3}
!java-method-compilation = !{}

!0 = !{!"r15"}
!1 = !{!"rsp"}
!2 = !{i32 5}
!3 = !{i32 15}
!4 = !{!"branch_weights", i32 1, i32 2048}
!5 = !{}
!6 = !{!"branch_weights", i32 500000, i32 500000}
!7 = !{!"branch_weights", i32 1, i32 999999}
