; RUN: opt -S -passes="recover-type-info" -jeandle-vm-callback-log=%S/Inputs/recover-osr-checkcast-edge.cblog %s 2>&1 | FileCheck %s

; OSR entry shape: %arr is a naked load from the OSR buffer — no metadata, no
; attributes. The OSR-entry checkcast (phase 0, dissolved by SimplifyCFG)
; leaves two edges into %pass: the null edge from %site (skipped — it carries
; no non-null constraint) and the check edge from %check_subtype proving klass
; 40 (an object array). RecoverTypeInfo must therefore resolve the element
; load's klass to the array element klass 41.

declare i1 @jeandle.check_instanceof(ptr addrspace(0), ptr addrspace(1) nonnull)

define void @test(ptr addrspace(0) %osr_buf) #0 gc "hotspotgc" {
site:
  %arr = load ptr addrspace(1), ptr addrspace(0) %osr_buf
  %is_null = icmp eq ptr addrspace(1) %arr, null
  br i1 %is_null, label %pass, label %check_subtype

check_subtype:
  %is_sub = call i1 @jeandle.check_instanceof(ptr addrspace(0) inttoptr (i64 40 to ptr addrspace(0)), ptr addrspace(1) nonnull %arr)
  br i1 %is_sub, label %pass, label %fail

pass:
  %elem_addr = getelementptr i8, ptr addrspace(1) %arr, i64 24
  %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr
  ret void

fail:
  ret void
}

; CHECK: %elem = load ptr addrspace(1), ptr addrspace(1) %elem_addr{{.*}}, !java-klass ![[K:[0-9]+]]
; CHECK: ![[K]] = !{i64 41}

attributes #0 = { "java-method"="0" }

!java-method-compilation = !{}
