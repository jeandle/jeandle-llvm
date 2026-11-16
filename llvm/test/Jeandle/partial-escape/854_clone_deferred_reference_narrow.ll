; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" -jeandle-vm-callback-log=%S/Inputs/852_clone_deferred_reference.cblog %s | FileCheck %s

; CHECK-LABEL: define ptr addrspace(1) @clone_deferred_reference_narrow
; CHECK-NOT: @jeandle.new_
; CHECK-NOT: @jeandle.copy
; CHECK: %[[VALUE:.*]] = load atomic ptr addrspace(3), {{.*}} unordered, align 4, !java-klass ![[TYPE:[0-9]+]]
; CHECK-NOT: @jeandle.new_
; CHECK-NOT: @jeandle.copy
; CHECK: %[[OOP:.*]] = addrspacecast ptr addrspace(3) %[[VALUE]] to ptr addrspace(1)
; CHECK: ret ptr addrspace(1) %[[OOP]]
; CHECK: ![[TYPE]] = !{i64 2001}

target datalayout = "e-p:64:64-p3:32:32"
@VMOptions.UseCompressedOops = constant i1 true
@arrayOopDesc.element_size.object = constant i32 4
@instanceOopDesc.base_offset_in_bytes = constant i64 16
declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

define ptr addrspace(1) @clone_deferred_reference_narrow(ptr addrspace(1) nonnull "java-klass"="30001" "java-klass-exact" %source) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %tmp = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr inttoptr (i64 30001 to ptr), i32 24, i1 false) to label %copy_first unwind label %u
copy_first:
  invoke void @jeandle.copy(ptr addrspace(1) %source, i64 16, ptr addrspace(1) %tmp, i64 16, i64 1, ptr null, ptr null, i64 24, i64 24) #0 to label %read_first unwind label %u
read_first:
  %tp = getelementptr inbounds i8, ptr addrspace(1) %tmp, i64 16
  %nv = load atomic ptr addrspace(3), ptr addrspace(1) %tp unordered, align 4, !java-klass !0
  %value = addrspacecast ptr addrspace(3) %nv to ptr addrspace(1)
  %box = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 1000 to ptr), i32 1, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %store_box unwind label %u
store_box:
  %bp = getelementptr inbounds i8, ptr addrspace(1) %box, i64 16
  store atomic ptr addrspace(3) %nv, ptr addrspace(1) %bp unordered, align 4
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 2000 to ptr), i32 1, i32 24, i32 16, i32 1048576, i1 false, i1 false) to label %copy_second unwind label %u
copy_second:
  invoke void @jeandle.copy(ptr addrspace(1) %box, i64 0, ptr addrspace(1) %dst, i64 0, i64 1, ptr null, ptr null, i64 1, i64 1) #1 to label %read_second unwind label %u
read_second:
  %dp = getelementptr inbounds i8, ptr addrspace(1) %dst, i64 16
  %nr = load atomic ptr addrspace(3), ptr addrspace(1) %dp unordered, align 4, !java-klass !0
  %result = addrspacecast ptr addrspace(3) %nr to ptr addrspace(1)
  ret ptr addrspace(1) %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}
attributes #0 = { "jeandle.copy.kind"="clone-instance" "jeandle.copy.tightly-coupled-allocation" }
attributes #1 = { "jeandle.copy.kind"="arraycopy" }
!0 = !{i64 2001}


!java-method-compilation = !{}
